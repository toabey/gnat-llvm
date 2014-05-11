with Ada.Containers;          use Ada.Containers;
with Interfaces.C;            use Interfaces.C;
with Interfaces.C.Extensions; use Interfaces.C.Extensions;
with System;

with Einfo;    use Einfo;
with Errout;   use Errout;
with Namet;    use Namet;
with Nlists;   use Nlists;
with Sem_Util; use Sem_Util;
with Snames;   use Snames;
with Stringt;  use Stringt;
with Uintp;    use Uintp;

with LLVM.Analysis; use LLVM.Analysis;

with GNATLLVM.Arrays;       use GNATLLVM.Arrays;
with GNATLLVM.Bounds;       use GNATLLVM.Bounds;
with GNATLLVM.Builder;      use GNATLLVM.Builder;
with GNATLLVM.Nested_Subps; use GNATLLVM.Nested_Subps;
with GNATLLVM.Types;        use GNATLLVM.Types;
with GNATLLVM.Utils;        use GNATLLVM.Utils;
with LLVM.Target; use LLVM.Target;

package body GNATLLVM.Compile is

   pragma Annotate (Xcov, Exempt_On, "Defensive programming");

   function Get_Type_Size
     (Env : Environ;
      T   : Type_T) return Value_T;
   --  Return the size of an LLVM type, in bytes
   function Record_Field_Offset
     (Env : Environ;
      Record_Ptr : Value_T;
      Record_Field : Node_Id) return Value_T;

   function Build_Type_Conversion
     (Env                 : Environ;
      Src_Type, Dest_Type : Entity_Id;
      Value               : Value_T) return Value_T;
   --  Emit code to convert Src_Value to Dest_Type

   function Emit_Attribute_Reference
     (Env  : Environ;
      Node : Node_Id) return Value_T
     with Pre => Nkind (Node) = N_Attribute_Reference;
   --  Helper for Emit_Expression: handle N_Attribute_Reference nodes

   function Emit_Call
     (Env : Environ; Call_Node : Node_Id) return Value_T;
   --  Helper for Emit/Emit_Expression: compile a call statement/expression and
   --  return its result value.

   function Emit_Comparison
     (Env          : Environ;
      Operation    : Pred_Mapping;
      Operand_Type : Entity_Id;
      LHS, RHS     : Node_Id) return Value_T;
   --  Helper for Emit_Expression: handle comparison operations

   function Emit_If
     (Env  : Environ;
      Node : Node_Id) return Value_T
     with Pre => Nkind (Node) in N_If_Statement | N_If_Expression;
   --  Helper for Emit and Emit_Expression: handle if statements and if
   --  expressions.

   procedure Emit_List
     (Env : Environ; List : List_Id);
   --  Helper for Emit/Emit_Expression: call Emit on every element of List

   function Emit_Min_Max
     (Env         : Environ;
      Exprs       : List_Id;
      Compute_Max : Boolean) return Value_T
     with Pre => List_Length (Exprs) = 2
     and then Is_Scalar_Type (Etype (First (Exprs)));
   --  Exprs must be a list of two scalar expressions with compatible types.
   --  Emit code to evaluate both expressions. If Compute_Max, return the
   --  maximum value and return the minimum otherwise.

   function Emit_Shift
     (Env       : Environ;
      Operation : Node_Kind;
      LHS, RHS  : Value_T) return Value_T;
   --  Helper for Emit_Expression: handle shift and rotate operations

   function Emit_Subprogram_Decl
     (Env : Environ; Subp_Spec : Node_Id) return Value_T;
   --  Compile a subprogram declaration, save the corresponding LLVM value to
   --  the environment and return it.

   function Emit_Type_Size
     (Env                   : Environ;
      T                     : Entity_Id;
      Array_Descr           : Value_T;
      Containing_Record_Ptr : Value_T) return Value_T;
   --  Helper for Emit/Emit_Expression: emit code to compute the size of type
   --  T, getting information from Containing_Record_Ptr for types that are
   --  constrained by a discriminant record (in such case, this parameter
   --  should be a pointer to the corresponding record). If T is an
   --  unconstrained array, Array_Descr must be the corresponding fat
   --  pointer. Return the computed size as value.

   function Create_Callback_Wrapper
     (Env : Environ; Subp : Entity_Id) return Value_T;
   --  If Subp takes a static link, return its LLVM declaration. Otherwise,
   --  create a wrapper declaration to it that accepts a static link and
   --  return it.

   procedure Attach_Callback_Wrapper_Body
     (Env : Environ; Subp : Entity_Id; Wrapper : Value_T);
   --  If Subp takes a static link, do nothing. Otherwise, add the
   --  implementation of its wrapper.

   procedure Match_Static_Link_Variable
     (Env       : Environ;
      Def_Ident : Entity_Id;
      LValue    : Value_T);
   --  If Def_Ident belongs to the closure of the current static link
   --  descriptor, reference it to the static link structure. Do nothing
   --  if there is no current subprogram.

   function Get_Static_Link
     (Env  : Environ;
      Subp : Entity_Id) return Value_T;
   --  Build and return the appropriate static link to pass to a call to Subp

   pragma Annotate (Xcov, Exempt_Off, "Defensive programming");

   -------------------
   -- Get_Type_Size --
   -------------------

   function Get_Type_Size
     (Env : Environ;
      T   : Type_T) return Value_T
   is
      T_Data : constant Target_Data_T :=
        Create_Target_Data (Get_Target (Env.Mdl));
   begin
      return Const_Int
        (Int_Ptr_Type,
         Size_Of_Type_In_Bits (T_Data, T) / 8,
         Sign_Extend => False);
   end Get_Type_Size;

   --------------------
   -- Emit_Type_Size --
   --------------------

   function Emit_Type_Size
     (Env                   : Environ;
      T                     : Entity_Id;
      Array_Descr           : Value_T;
      Containing_Record_Ptr : Value_T) return Value_T
   is
      LLVM_Type : constant Type_T := Create_Type (Env, T);
   begin
      if Is_Scalar_Type (T)
        or else Is_Access_Type (T)
      then
         return Get_Type_Size (Env, LLVM_Type);
      elsif Is_Array_Type (T) then
         return Env.Bld.Mul
           (Emit_Type_Size
              (Env, Component_Type (T), No_Value_T, Containing_Record_Ptr),
            Array_Size
              (Env, Array_Descr, T, Containing_Record_Ptr),
            "array-size");
      else
         raise Constraint_Error with "Unimplemented case for emit type size";
      end if;
   end Emit_Type_Size;

   -------------------------
   -- Record_Field_Offset --
   -------------------------

   function Record_Field_Offset
     (Env : Environ;
      Record_Ptr : Value_T;
      Record_Field : Node_Id) return Value_T
   is
      Field_Id   : constant Entity_Id := Defining_Identifier (Record_Field);
      Type_Id    : constant Entity_Id := Scope (Field_Id);
      R_Info     : constant Record_Info := Env.Get (Type_Id);
      F_Info     : constant Field_Info := R_Info.Fields.Element (Field_Id);
      Struct_Ptr : Value_T := Record_Ptr;
   begin
      if F_Info.Containing_Struct_Index > 1 then
         declare
            Int_Struct_Address : Value_T := Env.Bld.Ptr_To_Int
              (Record_Ptr, Int_Ptr_Type, "offset-calc");
            S_Info : constant Struct_Info :=
              R_Info.Structs (F_Info.Containing_Struct_Index);
         begin
            --  Accumulate the size of every field
            for Preceding_Field of S_Info.Preceding_Fields loop
               Int_Struct_Address := Env.Bld.Add
                 (Int_Struct_Address,
                  Emit_Type_Size
                    (Env,
                     Etype (Preceding_Field.Entity),
                     No_Value_T,
                     Record_Ptr),
                  "offset-calc");
            end loop;

            Struct_Ptr := Env.Bld.Int_To_Ptr
              (Int_Struct_Address, Pointer_Type (S_Info.LLVM_Type, 0), "back");
         end;
      end if;

      return Env.Bld.Struct_GEP
        (Struct_Ptr, unsigned (F_Info.Index_In_Struct), "field_access");
   end Record_Field_Offset;

   ---------------------------
   -- Emit_Compilation_Unit --
   ---------------------------

   procedure Emit_Compilation_Unit
     (Env : Environ; Node : Node_Id; Emit_Library_Unit : Boolean) is
   begin
      Env.Begin_Declarations;
      for With_Clause of Iterate (Context_Items (Node)) loop
         Emit (Env, With_Clause);
      end loop;
      Env.End_Declarations;

      if Emit_Library_Unit
        and then Present (Library_Unit (Node))
        and then Library_Unit (Node) /= Node
      then
         --  Library unit spec and body point to each other. Avoid infinite
         --  recursion.

         Emit_Compilation_Unit (Env, Library_Unit (Node), False);
      end if;
      Emit (Env, Unit (Node));
   end Emit_Compilation_Unit;

   ----------
   -- Emit --
   ----------

   procedure Emit
     (Env : Environ; Node : Node_Id) is
   begin
      case Nkind (Node) is

         when N_Compilation_Unit =>
            pragma Annotate (Xcov, Exempt_On, "Defensive programming");
            raise Program_Error with
              "N_Compilation_Unit node must be processed in"
              & " Emit_Compilation_Unit";
            pragma Annotate (Xcov, Exempt_Off);

         when N_With_Clause =>
            Emit_Compilation_Unit (Env, Library_Unit (Node), True);

         when N_Use_Package_Clause =>
            null;

         when N_Package_Declaration =>
            Emit (Env, Specification (Node));

         when N_Package_Specification =>
            Emit_List (Env, Visible_Declarations (Node));
            Emit_List (Env, Private_Declarations (Node));

         when N_Package_Body =>
            declare
               Def_Id : constant Entity_Id := Unique_Defining_Entity (Node);
            begin
               if Ekind (Def_Id) not in Generic_Unit_Kind then
                  Emit_List (Env, Declarations (Node));
                  --  TODO : Handle statements
               end if;
            end;

         when N_Subprogram_Declaration =>
            Discard (Emit_Subprogram_Decl (Env, Specification (Node)));

         when N_Subprogram_Body =>
            --  If we are processing only declarations, do not emit a
            --  subprogram body: just declare this subprogram and add it to
            --  the environment.

            if Env.In_Declarations then
               Discard (Emit_Subprogram_Decl (Env, Get_Acting_Spec (Node)));
               return;

            --  There is nothing to emit for the template of a generic
            --  subprogram body: ignore them.

            elsif Ekind (Defining_Unit_Name (Get_Acting_Spec (Node)))
               in Generic_Subprogram_Kind
            then
                  return;
            end if;

            declare
               Spec       : constant Node_Id := Get_Acting_Spec (Node);
               Def_Ident  : constant Entity_Id := Defining_Unit_Name (Spec);
               Func       : constant Value_T :=
                 Emit_Subprogram_Decl (Env, Spec);
               Subp       : constant Subp_Env := Env.Enter_Subp (Node, Func);
               Wrapper    : Value_T;

               LLVM_Param : Value_T;
               LLVM_Var   : Value_T;
               Param      : Entity_Id;
               I          : Natural := 0;

            begin
               --  Create a value for the static-link structure

               Subp.S_Link := Env.Bld.Alloca
                 (Create_Static_Link_Type (Env, Subp.S_Link_Descr),
                  "static-link");

               --  Create a wrapper for this function, if needed, and add its
               --  implementation, still if needed.

               Wrapper := Create_Callback_Wrapper (Env, Def_Ident);
               Attach_Callback_Wrapper_Body (Env, Def_Ident, Wrapper);

               --  Register each parameter into a new scope
               Env.Push_Scope;

               for P of Iterate (Parameter_Specifications (Spec)) loop
                  LLVM_Param := Get_Param (Subp.Func, unsigned (I));
                  Param := Defining_Identifier (P);

                  --  Define a name for the parameter P (which is the I'th
                  --  parameter), and associate the corresponding LLVM value to
                  --  its entity.

                  --  Set the name of the llvm value

                  Set_Value_Name (LLVM_Param, Get_Name (Param));

                  --  Special case for structures passed by value, we want to
                  --  store a pointer to them on the stack, so do an alloca,
                  --  to be able to do GEP on them.

                  if Param_Needs_Ptr (Param)
                    and then not
                      (Ekind (Etype (Param)) in Record_Kind
                       and (Get_Type_Kind (Type_Of (LLVM_Param))
                            = Struct_Type_Kind))
                  then
                     LLVM_Var := LLVM_Param;
                  else
                     LLVM_Var := Env.Bld.Alloca
                       (Type_Of (LLVM_Param), Get_Name (Param));
                     Env.Bld.Store (LLVM_Param, LLVM_Var);
                  end if;

                  --  Add the parameter to the environnment

                  Env.Set (Param, LLVM_Var);

                  Match_Static_Link_Variable
                    (Env, Param, LLVM_Var);

                  I := I + 1;
               end loop;

               if Env.Takes_S_Link (Def_Ident) then

                  --  Rename the static link argument and link the static link
                  --  value to it.

                  declare
                     Parent_S_Link : constant Value_T :=
                       Get_Param (Subp.Func, unsigned (I));
                     Parent_S_Link_Type : constant Type_T :=
                       Pointer_Type
                         (Create_Static_Link_Type
                            (Env, Subp.S_Link_Descr.Parent),
                          0);
                     S_Link        : Value_T;
                  begin
                     Set_Value_Name (Parent_S_Link, "parent-static-link");
                     S_Link := Env.Bld.Load (Subp.S_Link, "static-link");
                     S_Link := Env.Bld.Insert_Value
                       (S_Link,
                        Env.Bld.Bit_Cast
                          (Parent_S_Link, Parent_S_Link_Type, ""),
                        0,
                        "updated-static-link");
                     Env.Bld.Store (S_Link, Subp.S_Link);
                  end;

                  --  Then "import" from the static link all the non-local
                  --  variables.

                  for Cur in Subp.S_Link_Descr.Accesses.Iterate loop
                     declare
                        use Local_Access_Maps;

                        Access_Info : Access_Record renames Element (Cur);
                        Depth       : Natural := Access_Info.Depth;
                        LValue      : Value_T := Subp.S_Link;

                        Idx_Type    : constant Type_T :=
                          Int32_Type_In_Context (Env.Ctx);
                        Zero        : constant Value_T :=
                          Const_Null (Idx_Type);
                        Idx         : Value_Array (1 .. 2) :=
                          (Zero, Zero);

                     begin
                        --  Get a pointer to the target parent static link
                        --  structure.

                        while Depth > 0 loop
                           LValue := Env.Bld.Load
                             (Env.Bld.GEP
                                (LValue,
                                 Idx'Address, Idx'Length,
                                 ""),
                              "");
                           Depth := Depth - 1;
                        end loop;

                        --  And then get the non-local variable as an lvalue

                        Idx (2) := Const_Int
                          (Idx_Type,
                           unsigned_long_long (Access_Info.Field),
                           Sign_Extend => False);
                        LValue := Env.Bld.Load
                          (Env.Bld.GEP
                             (LValue, Idx'Address, Idx'Length, ""),
                           "");

                        Set_Value_Name (LValue, Get_Name (Key (Cur)));
                        Env.Set (Key (Cur), LValue);
                     end;
                  end loop;

               end if;

               Emit_List (Env, Declarations (Node));
               Emit_List
                 (Env, Statements (Handled_Statement_Sequence (Node)));

               --  This point should not be reached: a return must have
               --  already... returned!

               Discard (Env.Bld.Unreachable);

               Env.Pop_Scope;
               Env.Leave_Subp;

               pragma Annotate (Xcov, Exempt_On, "Defensive programming");
               if Verify_Function (Subp.Func, Print_Message_Action) then
                  Error_Msg_N
                    ("The backend generated bad LLVM for this subprogram.",
                     Node);
                  Dump_LLVM_Module (Env.Mdl);
               end if;
               pragma Annotate (Xcov, Exempt_Off);
            end;

         when N_Raise_Constraint_Error =>

            --  TODO??? When exceptions handling will be implemented, implement
            --  this.

            null;

         when N_Raise_Storage_Error =>

            --  TODO??? When exceptions handling will be implemented, implement
            --  this.

            null;

         when N_Object_Declaration =>

            --  Object declarations are local variables allocated on the stack

            --  If we are processing only declarations, only declare the
            --  corresponding symbol at the LLVM level and add it to the
            --  environment.

            if Env.In_Declarations then

               --  TODO??? Handle top-level declarations

               return;
            end if;

            declare
               Def_Ident      : constant Node_Id := Defining_Identifier (Node);
               Obj_Def        : constant Node_Id := Object_Definition (Node);
               T              : constant Entity_Id := Etype (Def_Ident);
               LLVM_Type      : Type_T;
               LLVM_Var, Expr : Value_T;
            begin

               --  Strip useless entities such as the ones generated for
               --  renaming encodings.

               if Nkind (Obj_Def) = N_Identifier
                 and then Ekind (Entity (Obj_Def)) in Discrete_Kind
                 and then Esize (Entity (Obj_Def)) = 0
               then
                  return;
               end if;

               if Is_Array_Type (T) then

                  --  Alloca arrays are handled as follows:
                  --  * The total size is computed with Compile_Array_Size.
                  --  * The type of the innermost component is computed with
                  --    Get_Innermost_Component type.
                  --  * The result of the alloca is bitcasted to the proper
                  --    array type, so that multidimensional LLVM GEP
                  --    operations work properly.

                  LLVM_Type := Create_Access_Type (Env, T);

                  LLVM_Var := Env.Bld.Bit_Cast
                     (Env.Bld.Array_Alloca
                        (Get_Innermost_Component_Type (Env, T),
                         Array_Size (Env, No_Value_T, T),
                         "array-alloca"),
                     LLVM_Type,
                     Get_Name (Def_Ident));
               else
                  LLVM_Type := Create_Type (Env, T);
                  LLVM_Var := Env.Bld.Alloca (LLVM_Type,
                                              "local-" & Get_Name (Def_Ident));
               end if;

               Env.Set (Def_Ident, LLVM_Var);
               Match_Static_Link_Variable (Env, Def_Ident, LLVM_Var);

               if Present (Expression (Node))
                 and then not No_Initialization (Node)
               then
                  --  TODO??? Handle the Do_Range_Check_Flag
                  Expr := Emit_Expression (Env, Expression (Node));
                  Env.Bld.Store (Expr, LLVM_Var);
               end if;
            end;

         when N_Use_Type_Clause =>
            null;

         when N_Object_Renaming_Declaration =>
            declare
               Def_Ident : constant Node_Id := Defining_Identifier (Node);
               LLVM_Var  : Value_T;
            begin

               --  If the renamed object is already an l-value, keep it as-is.
               --  Otherwise, create one for it.

               if Is_LValue (Name (Node)) then
                  LLVM_Var := Emit_LValue (Env, Name (Node));
               else
                  LLVM_Var := Env.Bld.Alloca
                    (Create_Type (Env, Etype (Def_Ident)),
                     Get_Name (Def_Ident));
                  Env.Bld.Store (Emit_Expression (Env, Name (Node)), LLVM_Var);
               end if;
               Env.Set (Def_Ident, LLVM_Var);
               Match_Static_Link_Variable (Env, Def_Ident, LLVM_Var);
            end;

         when N_Subprogram_Renaming_Declaration =>
            declare
               Def_Ident : constant Entity_Id :=
                 Defining_Unit_Name (Specification (Node));
               Renamed_Subp : constant Value_T :=
                 Env.Get (Entity (Name (Node)));
            begin
               Env.Set (Def_Ident, Renamed_Subp);
            end;

         when N_Package_Renaming_Declaration =>
            --  At the moment, packages aren't materialized in LLVM IR, so
            --  there is nothing to do here.

            null;

         when N_Implicit_Label_Declaration =>
            Env.Set
              (Defining_Identifier (Node),
               Create_Basic_Block
                 (Env, Get_Name (Defining_Identifier (Node))));

         when N_Assignment_Statement =>
            declare
               Val : constant Value_T :=
                 Emit_Expression (Env, Expression (Node));
               Dest : constant Value_T := Emit_LValue (Env, Name (Node));
            begin
               Env.Bld.Store (Val, Dest);
            end;

         when N_Procedure_Call_Statement =>
            Discard (Emit_Call (Env, Node));

         when N_Null_Statement =>
            null;

         when N_Label =>
            declare
               BB : constant Basic_Block_T :=
                 Env.Get (Entity (Identifier (Node)));
            begin
               Discard (Env.Bld.Br (BB));
               Env.Bld.Position_At_End (BB);
            end;

         when N_Goto_Statement =>
            Discard (Env.Bld.Br (Env.Get (Entity (Name (Node)))));
            Env.Bld.Position_At_End
              (Env.Create_Basic_Block ("after-goto"));

         when N_Exit_Statement =>
            declare
               Exit_Point : constant Basic_Block_T :=
                 (if Present (Name (Node))
                  then Env.Get_Exit_Point (Entity (Name (Node)))
                  else Env.Get_Exit_Point);
               Next_BB    : constant Basic_Block_T :=
                 Env.Create_Basic_Block ("loop-after-exit");
            begin
               if Present (Condition (Node)) then
                  Discard
                    (Env.Bld.Cond_Br
                       (Emit_Expression (Env, Condition (Node)),
                        Exit_Point,
                        Next_BB));
               else
                  Discard (Env.Bld.Br (Exit_Point));
               end if;
               Env.Bld.Position_At_End (Next_BB);
            end;

         when N_Simple_Return_Statement =>
            if Present (Expression (Node)) then
               Discard
                 (Env.Bld.Ret (Emit_Expression (Env, Expression (Node))));
            else
               Discard (Env.Bld.Ret_Void);
            end if;
            Env.Bld.Position_At_End
              (Env.Create_Basic_Block ("unreachable"));

         when N_If_Statement =>
            Discard (Emit_If (Env, Node));

         when N_Loop_Statement =>
            declare
               Loop_Identifier   : constant Entity_Id :=
                 (if Present (Identifier (Node))
                  then Entity (Identifier (Node))
                  else Empty);
               Iter_Scheme       : constant Node_Id :=
                 Iteration_Scheme (Node);
               Is_Mere_Loop      : constant Boolean :=
                 not Present (Iter_Scheme);
               Is_For_Loop       : constant Boolean :=
                 not Is_Mere_Loop
                 and then
                   Present (Loop_Parameter_Specification (Iter_Scheme));

               BB_Init, BB_Cond  : Basic_Block_T;
               BB_Stmts, BB_Iter : Basic_Block_T;
               BB_Next           : Basic_Block_T;
               Cond              : Value_T;
            begin
               --  The general format for a loop is:
               --    INIT;
               --    while COND loop
               --       STMTS;
               --       ITER;
               --    end loop;
               --    NEXT:
               --  Each step has its own basic block. When a loop does not need
               --  one of these steps, just alias it with another one.

               --  If this loop has an identifier, and it has already its own
               --  entry (INIT) basic block. Create one otherwise.
               BB_Init :=
                 (if Present (Identifier (Node))
                  then Env.Get (Entity (Identifier (Node)))
                  else Create_Basic_Block (Env, ""));
               Discard (Env.Bld.Br (BB_Init));
               Env.Bld.Position_At_End (BB_Init);

               --  If this is not a FOR loop, there is no initialization: alias
               --  it with the COND block.
               BB_Cond :=
                 (if not Is_For_Loop
                  then BB_Init
                  else Env.Create_Basic_Block ("loop-cond"));

               --  If this is a mere loop, there is even no condition block:
               --  alias it with the STMTS block.
               BB_Stmts :=
                 (if Is_Mere_Loop
                  then BB_Cond
                  else Env.Create_Basic_Block ("loop-stmts"));

               --  If this is not a FOR loop, there is no iteration: alias it
               --  with the COND block, so that at the end of every STMTS, jump
               --  on ITER or COND.
               BB_Iter :=
                 (if Is_For_Loop then Env.Create_Basic_Block ("loop-iter")
                  else BB_Cond);

               --  The NEXT step contains no statement that comes from the
               --  loop: it is the exit point.
               BB_Next := Create_Basic_Block (Env, "loop-exit");

               --  The front-end expansion can produce identifier-less loops,
               --  but exit statements can target them anyway, so register such
               --  loops.

               Env.Push_Loop (Loop_Identifier, BB_Next);
               Env.Push_Scope;

               --  First compile the iterative part of the loop: evaluation of
               --  the exit condition, etc.
               if not Is_Mere_Loop then
                  if not Is_For_Loop then
                     --  This is a WHILE loop: jump to the loop-body if the
                     --  condition evaluates to True, jump to the loop-exit
                     --  otherwise.
                     Env.Bld.Position_At_End (BB_Cond);
                     Cond := Emit_Expression (Env, Condition (Iter_Scheme));
                     Discard (Env.Bld.Cond_Br (Cond, BB_Stmts, BB_Next));

                  else
                     --  This is a FOR loop
                     declare
                        Loop_Param_Spec : constant Node_Id :=
                          Loop_Parameter_Specification (Iter_Scheme);
                        Def_Ident       : constant Node_Id :=
                          Defining_Identifier (Loop_Param_Spec);
                        Reversed        : constant Boolean :=
                          Reverse_Present (Loop_Param_Spec);
                        Unsigned_Type   : constant Boolean :=
                          Is_Unsigned_Type (Etype (Def_Ident));
                        LLVM_Type       : Type_T;
                        LLVM_Var        : Value_T;
                        Low, High       : Value_T;
                     begin
                        --  Initialization block: create the loop variable and
                        --  initialize it.
                        Create_Discrete_Type
                          (Env, Etype (Def_Ident), LLVM_Type, Low, High);
                        LLVM_Var := Env.Bld.Alloca
                          (LLVM_Type, Get_Name (Def_Ident));
                        Env.Set (Def_Ident, LLVM_Var);
                        Env.Bld.Store
                          ((if Reversed then High else Low), LLVM_Var);

                        --  Then go to the condition block if the range isn't
                        --  empty.
                        Cond := Env.Bld.I_Cmp
                          ((if Unsigned_Type then Int_ULE else Int_SLE),
                           Low, High,
                           "loop-entry-cond");
                        Discard (Env.Bld.Cond_Br (Cond, BB_Cond, BB_Next));

                        --  The FOR loop is special: the condition is evaluated
                        --  during the INIT step and right before the ITER
                        --  step, so there is nothing to check during the
                        --  COND step.
                        Env.Bld.Position_At_End (BB_Cond);
                        Discard (Env.Bld.Br (BB_Stmts));

                        BB_Cond := Env.Create_Basic_Block ("loop-cond-iter");
                        Env.Bld.Position_At_End (BB_Cond);
                        Cond := Env.Bld.I_Cmp
                          (Int_EQ,
                           Env.Bld.Load (LLVM_Var, "loop-var"),
                           (if Reversed then Low else High),
                            "loop-iter-cond");
                        Discard (Env.Bld.Cond_Br (Cond, BB_Next, BB_Iter));

                        --  After STMTS, stop if the loop variable was equal to
                        --  the "exit" bound. Increment/decrement it otherwise.
                        Env.Bld.Position_At_End (BB_Iter);
                        declare
                           Iter_Prev_Value : constant Value_T :=
                             Env.Bld.Load (LLVM_Var, "loop-var");
                           One             : constant Value_T :=
                             Const_Int
                               (LLVM_Type, 1, False);
                           Iter_Next_Value : constant Value_T :=
                             (if Reversed
                              then Env.Bld.Sub
                                (Iter_Prev_Value, One, "next-loop-var")
                              else Env.Bld.Add
                                (Iter_Prev_Value, One, "next-loop-var"));
                        begin
                           Env.Bld.Store (Iter_Next_Value, LLVM_Var);
                        end;
                        Discard (Env.Bld.Br (BB_Stmts));

                        --  The ITER step starts at this special COND step
                        BB_Iter := BB_Cond;
                     end;
                  end if;
               end if;

               Env.Bld.Position_At_End (BB_Stmts);
               Emit_List (Env, Statements (Node));
               Discard (Env.Bld.Br (BB_Iter));

               Env.Pop_Scope;
               Env.Pop_Loop;

               Env.Bld.Position_At_End (BB_Next);
            end;

         when N_Block_Statement =>
            declare
               BE          : constant Entity_Id :=
                 (if Present (Identifier (Node))
                  then Entity (Identifier (Node))
                  else Empty);
               BB          : Basic_Block_T;
               Stack_State : Value_T;

            begin
               --  The frontend can generate basic blocks with identifiers
               --  that are not declared: try to get any existing basic block,
               --  create and register a new one if it does not exist yet.

               if Env.Has_BB (BE) then
                  BB := Env.Get (BE);
               else
                  BB := Create_Basic_Block (Env, "");
                  if Present (BE) then
                     Env.Set (BE, BB);
                  end if;
               end if;
               Discard (Env.Bld.Br (BB));
               Env.Bld.Position_At_End (BB);

               Env.Push_Scope;
               Stack_State := Env.Bld.Call
                 (Get_Stack_Save (Env), System.Null_Address, 0, "");

               Emit_List (Env, Declarations (Node));
               Emit_List
                 (Env, Statements (Handled_Statement_Sequence (Node)));

               Discard
                 (Env.Bld.Call
                    (Get_Stack_Restore (Env), Stack_State'Address, 1, ""));

               Env.Pop_Scope;
            end;

         when N_Full_Type_Declaration | N_Subtype_Declaration
            | N_Incomplete_Type_Declaration | N_Private_Type_Declaration =>
            Env.Set (Defining_Identifier (Node),
                     Create_Type (Env, Defining_Identifier (Node)));

         when N_Freeze_Entity =>
            Emit_List (Env, Actions (Node));

         when N_Pragma =>
            case Get_Pragma_Id (Node) is
               --  TODO??? While we aren't interested in most of the pragmas,
               --  there are some we should look at. But still, the "others"
               --  case is necessary.
               when others => null;
            end case;

         --  Nodes we actually want to ignore
         when N_Empty
            | N_Function_Instantiation
            | N_Package_Instantiation
            | N_Generic_Package_Declaration
            | N_Generic_Subprogram_Declaration
            | N_Itype_Reference
            | N_Number_Declaration
            | N_Procedure_Instantiation
            | N_Validate_Unchecked_Conversion =>
            null;

         when N_Attribute_Definition_Clause =>
            if Get_Name (Node) = "alignment" then
               --  TODO??? Handle the alignment clause
               null;
            elsif Get_Name (Node) = "size" then
               --  TODO??? Handle size clauses
               null;
            else
               pragma Annotate (Xcov, Exempt_On, "Defensive programming");
               raise Program_Error
                 with "Unhandled attribute definition clause: "
                 & Get_Name (Node);
               pragma Annotate (Xcov, Exempt_Off);
            end if;

         when others =>
            pragma Annotate (Xcov, Exempt_On, "Defensive programming");
            raise Program_Error
              with "Unhandled statement node kind: "
              & Node_Kind'Image (Nkind (Node));
            pragma Annotate (Xcov, Exempt_Off);

      end case;
   end Emit;

   -----------------
   -- Emit_LValue --
   -----------------

   function Emit_LValue (Env : Environ; Node : Node_Id) return Value_T
   is
   begin
      case Nkind (Node) is
         when N_Identifier | N_Expanded_Name =>
            declare
               Def_Ident : constant Entity_Id := Entity (Node);
            begin
               if Ekind (Def_Ident) = E_Function
                 or else Ekind (Def_Ident) = E_Procedure
               then
                  --  Return a callback, which is a couple: subprogram code
                  --  pointer, static link argument.

                  declare
                     Func   : constant Value_T :=
                       Create_Callback_Wrapper (Env, Def_Ident);
                     S_Link : constant Value_T :=
                       Get_Static_Link (Env, Def_Ident);

                     Fields_Types : constant array (1 .. 2) of Type_T :=
                       (Type_Of (Func),
                        Type_Of (S_Link));
                     Callback_Type : constant Type_T :=
                       Struct_Type_In_Context
                         (Env.Ctx,
                          Fields_Types'Address, Fields_Types'Length,
                          Packed => False);

                     Result : Value_T := Get_Undef (Callback_Type);

                  begin
                     Result := Env.Bld.Insert_Value (Result, Func, 0, "");
                     Result := Env.Bld.Insert_Value
                       (Result, S_Link, 1, "callback");
                     return Result;
                  end;

               else
                  return Env.Get (Def_Ident);
               end if;
            end;

         when N_Explicit_Dereference =>
            return Emit_Expression (Env, Prefix (Node));

         when N_Aggregate =>
            declare
               --  The frontend can sometimes take a reference to an aggregate.
               --  In such cases, we have to create an anonymous object and use
               --  its value as the aggregate value.

               --  ??? This alloca will not necessarily be free'd before
               --  returning from the current subprogram: it's a leak.

               T : constant Type_T := Create_Type (Env, Etype (Node));
               V : constant Value_T := Env.Bld.Alloca (T, "anonymous-obj");

            begin
               Env.Bld.Store (Emit_Expression (Env, Node), V);
               return V;
            end;

         when N_Selected_Component =>
            declare
               Pfx_Ptr : constant Value_T :=
                 Emit_LValue (Env, Prefix (Node));
               Record_Component : constant Entity_Id :=
                 Parent (Entity (Selector_Name (Node)));
            begin
               return Record_Field_Offset (Env, Pfx_Ptr, Record_Component);
            end;

         when N_Indexed_Component =>
            declare
               Array_Node  : constant Node_Id := Prefix (Node);
               Array_Type  : constant Entity_Id := Etype (Array_Node);

               Array_Descr    : constant Value_T :=
                 Emit_LValue (Env, Prefix (Node));
               Array_Data_Ptr : constant Value_T :=
                 Array_Data (Env, Array_Descr, Array_Type);

               Idxs    :
               Value_Array (1 .. List_Length (Expressions (Node)) + 1) :=
                 (1      => Const_Int (Intptr_T, 0, Sign_Extend => False),
                  others => <>);
               --  Operands for the GetElementPtr instruction: one for the
               --  pointer deference, and then one per array index.

               I       : Nat := 2;
            begin

               for N of Iterate (Expressions (Node)) loop
                  --  Adjust the index according to the range lower bound

                  declare
                     User_Index    : constant Value_T :=
                       Emit_Expression (Env, N);
                     Dim_Low_Bound : constant Value_T :=
                       Array_Bound
                         (Env, Array_Descr, Array_Type, Low, Integer (I - 1));
                  begin
                     Idxs (I) :=
                       Env.Bld.Sub (User_Index, Dim_Low_Bound, "index");
                  end;

                  I := I + 1;
               end loop;

               return Env.Bld.GEP
                 (Array_Data_Ptr, Idxs, "array-element-access");
            end;

         when N_Slice =>
            declare
               Array_Node     : constant Node_Id := Prefix (Node);
               Array_Type     : constant Entity_Id := Etype (Array_Node);

               Array_Descr    : constant Value_T :=
                 Emit_LValue (Env, Array_Node);
               Array_Data_Ptr : constant Value_T :=
                 Array_Data (Env, Array_Descr, Array_Type);

               --  Compute how much we need to offset the array pointer. Slices
               --  can be built only on single-dimension arrays

               Index_Shift : constant Value_T :=
                 Env.Bld.Sub
                   (Emit_Expression (Env, Low_Bound (Discrete_Range (Node))),
                    Array_Bound (Env, Array_Descr, Array_Type, Low),
                    "offset");
            begin
               return Env.Bld.Bit_Cast
                 (Env.Bld.GEP
                    (Array_Data_Ptr,
                     (Const_Int (Intptr_T, 0, Sign_Extend => False),
                      Index_Shift),
                     "array-shifted"),
                  Create_Access_Type (Env, Etype (Node)),
                  "slice");
            end;

         when others =>
            pragma Annotate (Xcov, Exempt_On, "Defensive programming");
            raise Program_Error
              with "Unhandled node kind: " & Node_Kind'Image (Nkind (Node));
            pragma Annotate (Xcov, Exempt_Off);
      end case;
   end Emit_LValue;

   ---------------------
   -- Emit_Expression --
   ---------------------

   function Emit_Expression
     (Env : Environ; Node : Node_Id) return Value_T is

      function Emit_Expr (Node : Node_Id) return Value_T is
        (Emit_Expression (Env, Node));
      --  Shortcut to Emit_Expression. Used to implicitely pass the
      --  environment during recursion.

      type Scl_Op is (Op_Or, Op_And);

      function Build_Scl_Op (Op : Scl_Op) return Value_T;
      --  Emit the LLVM IR for a short circuit operator ("or else", "and then")

      function Build_Scl_Op (Op : Scl_Op) return Value_T is
      begin
         declare

            --  The left expression of a SCL op is always evaluated.

            Left : constant Value_T := Emit_Expr (Left_Opnd (Node));
            Result : constant Value_T :=
              Env.Bld.Alloca (Type_Of (Left), "scl-res-1");

            --  Block which contains the evaluation of the right part
            --  expression of the operator.

            Block_Right_Expr : constant Basic_Block_T :=
              Append_Basic_Block (Env.Current_Subp.Func, "scl-right-expr");

            --  Block containing the exit code (load the final cond value into
            --  Result

            Block_Exit : constant Basic_Block_T :=
              Append_Basic_Block (Env.Current_Subp.Func, "scl-exit");

         begin
            Env.Bld.Store (Left, Result);

            --  In the case of And, evaluate the right expression when Left is
            --  true. In the case of Or, evaluate it when Left is false.

            if Op = Op_And then
               Discard
                 (Env.Bld.Cond_Br (Left, Block_Right_Expr, Block_Exit));
            else
               Discard
                 (Env.Bld.Cond_Br (Left, Block_Exit, Block_Right_Expr));
            end if;

            --  Emit code for the evaluation of the right part expression

            Position_At_End (Env.Bld, Block_Right_Expr);

            declare
               Right : constant Value_T := Emit_Expr (Right_Opnd (Node));
               Left : constant Value_T := Env.Bld.Load (Result, "load-left");
               Res : Value_T;
            begin
               if Op = Op_And then
                  Res := Build_And (Env.Bld, Left, Right, "scl-and");
               else
                  Res := Build_Or (Env.Bld, Left, Right, "scl-or");
               end if;
               Env.Bld.Store (Res, Result);
               Discard (Env.Bld.Br (Block_Exit));
            end;

            Position_At_End (Env.Bld, Block_Exit);

            return Env.Bld.Load (Result, "scl-final-res");
         end;
      end Build_Scl_Op;

   begin
      if Is_Binary_Operator (Node) then
         case Nkind (Node) is
            when N_Op_Gt | N_Op_Lt | N_Op_Le | N_Op_Ge | N_Op_Eq | N_Op_Ne =>
               return Emit_Comparison
                 (Env,
                  Get_Preds (Node),
                  Get_Fullest_View (Etype (Left_Opnd (Node))),
                  Left_Opnd (Node), Right_Opnd (Node));

            when others =>
               null;
         end case;

         declare
            LVal : constant Value_T :=
              Emit_Expr (Left_Opnd (Node));
            RVal : constant Value_T :=
              Emit_Expr (Right_Opnd (Node));
            Op : Value_T;

         begin
            case Nkind (Node) is

            when N_Op_Add =>
               Op := Env.Bld.Add (LVal, RVal, "add");

            when N_Op_Subtract =>
               Op := Env.Bld.Sub (LVal, RVal, "sub");

            when N_Op_Multiply =>
               Op := Env.Bld.Mul (LVal, RVal, "mul");

            when N_Op_Divide =>
               declare
                  T : constant Entity_Id := Etype (Left_Opnd (Node));
               begin
                  if Is_Signed_Integer_Type (T) then
                     Op := Env.Bld.S_Div (LVal, RVal, "sdiv");
                  elsif Is_Floating_Point_Type (T) then
                     Op := Env.Bld.F_Div (LVal, RVal, "fdiv");
                  elsif Is_Unsigned_Type (T) then
                     return Env.Bld.U_Div (LVal, RVal, "udiv");
                  else
                     pragma Annotate
                       (Xcov, Exempt_On, "Defensive programming");
                     raise Program_Error
                       with "Not handled : Division with type " & T'Img;
                     pragma Annotate (Xcov, Exempt_Off);
                  end if;
               end;

            when N_Op_Rem =>
               Op :=
                 (if Is_Unsigned_Type (Etype (Left_Opnd (Node)))
                  then Env.Bld.U_Rem (LVal, RVal, "urem")
                  else Env.Bld.S_Rem (LVal, RVal, "srem"));

            when N_Op_And =>
               Op := Env.Bld.Build_And (LVal, RVal, "and");

            when N_Op_Or =>
                  Op := Env.Bld.Build_Or (LVal, RVal, "or");

            when N_Op_Xor =>
               Op := Env.Bld.Build_Xor (LVal, RVal, "xor");

            when N_Op_Shift_Left | N_Op_Shift_Right
               | N_Op_Shift_Right_Arithmetic
               | N_Op_Rotate_Left | N_Op_Rotate_Right =>
               return Emit_Shift (Env, Nkind (Node), LVal, RVal);

            when others =>
               pragma Annotate (Xcov, Exempt_On, "Defensive programming");
               raise Program_Error
                 with "Unhandled node kind in expression: "
                 & Node_Kind'Image (Nkind (Node));
               pragma Annotate (Xcov, Exempt_Off);

            end case;

            --  We need to handle modulo manually for non binary modulus types.

            if Non_Binary_Modulus (Etype (Node)) then
               Op := Env.Bld.U_Rem
                 (Op,
                  Const_Int
                    (Create_Type (Env, Etype (Node)), Modulus (Etype (Node))),
                 "mod");
            end if;

            return Op;
         end;

      else

         case Nkind (Node) is

         when N_Expression_With_Actions =>
            --  TODO??? Compile the list of actions
--              pragma Assert (Is_Empty_List (Actions (Node)));
            return Emit_Expr (Expression (Node));

         when N_Character_Literal =>
            return Const_Int
              (Create_Type (Env, Etype (Node)),
               Char_Literal_Value (Node));

         when N_Integer_Literal =>
            return Const_Int
              (Create_Type (Env, Etype (Node)),
               Intval (Node));

         when N_String_Literal =>
            declare
               String       : constant String_Id := Strval (Node);
               Array_Type   : constant Type_T :=
                 Create_Type (Env, Etype (Node));
               Element_Type : constant Type_T := Get_Element_Type (Array_Type);
               Length       : constant Interfaces.C.unsigned :=
                 Get_Array_Length (Array_Type);
               Elements     : array (1 .. Length) of Value_T;
            begin
               for I in Elements'Range loop
                  Elements (I) := Const_Int
                    (Element_Type,
                     unsigned_long_long
                       (Get_String_Char (String, Standard.Types.Int (I))),
                     Sign_Extend => True);
               end loop;
               return Const_Array (Element_Type, Elements'Address, Length);
            end;

         when N_And_Then => return Build_Scl_Op (Op_And);
         when N_Or_Else => return Build_Scl_Op (Op_Or);
         when N_Op_Not =>
            declare
               Expr      : constant Value_T :=
                 Emit_Expr (Right_Opnd (Node));
            begin
               return Env.Bld.Build_Xor
                 (Expr,
                  Const_Ones (Type_Of (Expr)),
                  "not");
            end;

         when N_Op_Plus => return Emit_Expr (Right_Opnd (Node));
         when N_Op_Minus => return Env.Bld.Sub
              (Const_Int
                 (Create_Type (Env, Etype (Node)), 0, False),
               Emit_Expr (Right_Opnd (Node)),
               "minus");

         when N_Unchecked_Type_Conversion =>
            declare
               Val     : constant Value_T := Emit_Expr (Expression (Node));
               Val_Ty  : constant Type_T := LLVM_Type_Of (Val);
               Dest_Ty : constant Type_T := Create_Type (Env, Etype (Node));
               Val_Tk  : constant Type_Kind_T := Get_Type_Kind (Val_Ty);
               Dest_Tk : constant Type_Kind_T := Get_Type_Kind (Dest_Ty);
            begin
               if Val_Tk = Pointer_Type_Kind then
                  return Env.Bld.Pointer_Cast
                    (Val, Dest_Ty, "unchecked-conv");
               elsif
                 Val_Tk = Integer_Type_Kind
                 and then Dest_Tk = Integer_Type_Kind
               then
                  return Env.Bld.Int_Cast
                    (Val, Dest_Ty, "unchecked-conv");
               elsif Val_Tk = Integer_Type_Kind
                 and then Dest_Tk = Pointer_Type_Kind
               then
                  return Env.Bld.Int_To_Ptr (Val, Dest_Ty, "unchecked-conv");
               else
                  pragma Annotate (Xcov, Exempt_On, "Defensive programming");
                  raise Program_Error
                    with "Invalid conversion, should never happen";
                  pragma Annotate (Xcov, Exempt_Off);
               end if;
            end;

         when N_Type_Conversion | N_Qualified_Expression =>
            return Build_Type_Conversion
              (Env       => Env,
               Src_Type  => Etype (Expression (Node)),
               Dest_Type => Etype (Node),
               Value     => Emit_Expr (Expression (Node)));

         when N_Identifier | N_Expanded_Name =>
            --  N_Defining_Identifier nodes for enumeration literals are not
            --  stored in the environment. Handle them here.

            if Ekind (Entity (Node)) = E_Enumeration_Literal then
               return Const_Int
                 (Create_Type (Env, Etype (Node)),
                  Enumeration_Rep (Entity (Node)), False);
            else
               --  LLVM functions are pointers that cannot be dereferenced. If
               --  Entity (Node) is a subprogram, return it as-is, the caller
               --  expects a pointer to a function anyway.

               declare
                  Def_Ident     : constant Entity_Id := Entity (Node);
                  Kind          : constant Entity_Kind := Ekind (Def_Ident);
                  Type_Kind     : constant Entity_Kind :=
                    Ekind (Etype (Def_Ident));
                  Is_Subprogram : constant Boolean :=
                    (Kind = E_Function
                     or else Kind = E_Procedure
                     or else Type_Kind = E_Subprogram_Type);

                  LValue : constant Value_T := Env.Get (Def_Ident);

               begin
                  return
                    (if Is_Subprogram
                     then LValue
                     else Env.Bld.Load (LValue, ""));
               end;
            end if;

         when N_Function_Call =>
            return Emit_Call (Env, Node);

         when N_Explicit_Dereference =>
            --  Access to subprograms require special handling, see
            --  N_Identifier.

            declare
               Access_Value : constant Value_T := Emit_Expr (Prefix (Node));
            begin
               return
                 (if Ekind (Etype (Node)) = E_Subprogram_Type
                  then Access_Value
                  else Env.Bld.Load (Access_Value, ""));
            end;

         when N_Allocator =>
            declare
               Arg : array (1 .. 1) of Value_T :=
                 (1 => Size_Of (Create_Type (Env, Etype (Expression (Node)))));
            begin
               if Nkind (Expression (Node)) = N_Identifier then
                  return Env.Bld.Bit_Cast
                    (Env.Bld.Call
                       (Env.Default_Alloc_Fn, Arg'Address, 1, "alloc"),
                     Create_Type (Env, Etype (Node)),
                     "alloc_bc");
               else
                  pragma Annotate (Xcov, Exempt_On, "Defensive programming");
                  raise Program_Error
                    with "Non handled form in N_Allocator";
                  pragma Annotate (Xcov, Exempt_Off);
               end if;
            end;

         when N_Reference =>
            return Emit_LValue (Env, Prefix (Node));

         when N_Attribute_Reference =>

            return Emit_Attribute_Reference (Env, Node);

         when N_Selected_Component =>
            declare
               Pfx_Val : constant Value_T :=
                 Emit_Expression (Env, Prefix (Node));
               Pfx_Ptr : constant Value_T :=
                 Env.Bld.Alloca (Type_Of (Pfx_Val), "pfx_ptr");
               Record_Component : constant Entity_Id :=
                 Parent (Entity (Selector_Name (Node)));
            begin
               Env.Bld.Store (Pfx_Val, Pfx_Ptr);
               return Env.Bld.Load
                 (Record_Field_Offset (Env, Pfx_Ptr, Record_Component), "");
            end;

         when N_Indexed_Component | N_Slice =>
            return Env.Bld.Load (Emit_LValue (Env, Node), "");

         when N_Aggregate =>
            declare
               Agg_Type   : constant Entity_Id := Etype (Node);
               LLVM_Type  : constant Type_T :=
                 Create_Type (Env, Agg_Type);
               Result     : Value_T := Get_Undef (LLVM_Type);
               Cur_Expr   : Value_T;
               Cur_Index  : Integer;
            begin
               if Ekind (Agg_Type) in Record_Kind then
                  for Assoc of Iterate (Component_Associations (Node)) loop
                     Cur_Expr := Emit_Expr (Expression (Assoc));
                     for Choice of Iterate (Choices (Assoc)) loop
                        Cur_Index := Index_In_List
                          (Parent (Entity (Choice)));
                        Result := Env.Bld.Insert_Value
                          (Result, Cur_Expr, unsigned (Cur_Index - 1), "");
                     end loop;
                  end loop;

                  --  Must be an array

               else
                  Cur_Index := 0;
                  for Expr of Iterate (Expressions (Node)) loop
                     Cur_Expr := Emit_Expr (Expr);
                     Result := Env.Bld.Insert_Value
                       (Result, Cur_Expr, unsigned (Cur_Index), "");
                     Cur_Index := Cur_Index + 1;
                  end loop;

               end if;

               return Result;
            end;

         when N_If_Expression =>
            return Emit_If (Env, Node);

         when N_Null =>
            return Const_Null (Create_Type (Env, Etype (Node)));

         when others =>
            pragma Annotate (Xcov, Exempt_On, "Defensive programming");
            raise Program_Error
              with "Unhandled node kind: " & Node_Kind'Image (Nkind (Node));
            pragma Annotate (Xcov, Exempt_Off);
         end case;
      end if;
   end Emit_Expression;

   ---------------
   -- Emit_List --
   ---------------

   procedure Emit_List
     (Env : Environ; List : List_Id) is
   begin
      for N of Iterate (List) loop
         Emit (Env, N);
      end loop;
   end Emit_List;

   function Emit_Call
     (Env : Environ; Call_Node : Node_Id) return Value_T
   is
      Subp        : constant Node_Id := Name (Call_Node);
      Params      : constant Entity_Iterator :=
        Get_Params (if Nkind (Subp) = N_Identifier
                    or else Nkind (Subp) = N_Expanded_Name
                    then Entity (Subp)
                    else Etype (Subp));
      Param_Assoc, Actual : Node_Id;
      Actual_Type         : Entity_Id;
      Current_Needs_Ptr   : Boolean;

      --  If it's not an identifier, it must be an access to a subprogram and
      --  in such a case, it must accept a static link.

      Takes_S_Link   : constant Boolean :=
        (Nkind (Subp) /= N_Identifier
         and then Nkind (Subp) /= N_Expanded_Name)
        or else Env.Takes_S_Link (Entity (Subp));

      S_Link         : Value_T;
      LLVM_Func      : Value_T;
      Args_Count     : constant Nat :=
        Params'Length + (if Takes_S_Link then 1 else 0);

      Args           : array (1 .. Args_Count) of Value_T;
      I, Idx         : Standard.Types.Int := 1;
      P_Type         : Entity_Id;
      Params_Offsets : Name_Maps.Map;
   begin
      for Param of Params loop
         Params_Offsets.Include (Chars (Param), I);
         I := I + 1;
      end loop;
      I := 1;

      LLVM_Func := Emit_Expression (Env, Name (Call_Node));

      if Nkind (Name (Call_Node)) /= N_Identifier
        and then Nkind (Name (Call_Node)) /= N_Expanded_Name
      then
         S_Link := Env.Bld.Extract_Value (LLVM_Func, 1, "static-link-ptr");
         LLVM_Func := Env.Bld.Extract_Value (LLVM_Func, 0, "callback");
      else
         S_Link := Get_Static_Link (Env, Entity (Name (Call_Node)));
      end if;

      Param_Assoc := First (Parameter_Associations (Call_Node));

      while Present (Param_Assoc) loop

         if Nkind (Param_Assoc) = N_Parameter_Association then
            Actual := Explicit_Actual_Parameter (Param_Assoc);
            Idx := Params_Offsets (Chars (Selector_Name (Param_Assoc)));
         else
            Actual := Param_Assoc;
            Idx := I;
         end if;
         Actual_Type := Etype (Actual);

         Current_Needs_Ptr := Param_Needs_Ptr (Params (Idx));
         Args (Idx) :=
           (if Current_Needs_Ptr
            then Emit_LValue (Env, Actual)
            else Emit_Expression (Env, Actual));

         P_Type := Etype (Params (Idx));

         --  At this point we need to handle view conversions: from array thin
         --  pointer to array fat pointer, unconstrained array pointer type
         --  conversion, ... For other parameters that needs to be passed
         --  as pointers, we should also make sure the pointed type fits
         --  the LLVM formal.

         if Is_Array_Type (Actual_Type) then

            if Is_Constrained (Actual_Type)
              and then not Is_Constrained (P_Type)
            then
               --  Convert from thin to fat pointer

               Args (Idx) :=
                 Array_Fat_Pointer (Env, Args (Idx), Etype (Actual));

            elsif not Is_Constrained (Actual_Type)
              and then Is_Constrained (P_Type)
            then
               --  Convert from fat to thin pointer

               Args (Idx) := Array_Data (Env, Args (Idx), Actual_Type);
            end if;

         elsif Current_Needs_Ptr then
            Args (Idx) := Env.Bld.Bit_Cast
              (Args (Idx), Create_Access_Type (Env, P_Type),
               "param-bitcast");
         end if;

         I := I + 1;
         Param_Assoc := Next (Param_Assoc);
      end loop;

      --  Set the argument for the static link, if any

      if Takes_S_Link then
         Args (Args'Last) := S_Link;
      end if;

      --  If there are any types mismatches for arguments passed by reference,
      --  bitcast the pointer type.

      declare
         Args_Types : constant Type_Array :=
           Get_Param_Types (Type_Of (LLVM_Func));
      begin
         for J in Args'Range loop
            if Type_Of (Args (J)) /= Args_Types (J)
              and then Get_Type_Kind (Type_Of (Args (J))) = Pointer_Type_Kind
            then
               Args (J) := Env.Bld.Bit_Cast (Args (J), Args_Types (J),
                                             "param-bitcast");
            end if;
         end loop;
      end;

      return
        Env.Bld.Call
          (LLVM_Func, Args'Address, Args'Length,
           --  Assigning a name to a void value is not possible with LLVM
           (if Nkind (Call_Node) = N_Function_Call then "subpcall" else ""));
   end Emit_Call;

   --------------------------
   -- Emit_Subprogram_Decl --
   --------------------------

   function Emit_Subprogram_Decl
     (Env : Environ; Subp_Spec : Node_Id) return Value_T
   is
      Def_Ident : constant Node_Id := Defining_Unit_Name (Subp_Spec);
   begin
      --  If this subprogram specification has already been compiled, do
      --  nothing.

      if Env.Has_Value (Def_Ident) then
         return Env.Get (Def_Ident);

      else
         declare
            Subp_Type : constant Type_T :=
              Create_Subprogram_Type_From_Spec (Env, Subp_Spec);

            Subp_Base_Name : constant String :=
                Get_Name_String (Chars (Def_Ident));
            Subp_Name : constant String :=
              (if Scope_Depth_Value (Def_Ident) > 1
               then Subp_Base_Name
               else "_ada_" & Subp_Base_Name);

            LLVM_Func : constant Value_T :=
              Add_Function (Env.Mdl, Subp_Name, Subp_Type);
         begin
            --  Define the appropriate linkage

            if not Is_Public (Def_Ident) then
               Set_Linkage (LLVM_Func, Internal_Linkage);
            end if;

            Env.Set (Def_Ident, LLVM_Func);
            return LLVM_Func;
         end;
      end if;
   end Emit_Subprogram_Decl;

   -----------------------------
   -- Create_Callback_Wrapper --
   -----------------------------

   function Create_Callback_Wrapper
     (Env : Environ; Subp : Entity_Id) return Value_T
   is
      use Value_Maps;
      Wrapper : constant Cursor := Env.Subp_Wrappers.Find (Subp);

      Result : Value_T;
   begin
      if Wrapper /= No_Element then
         return Element (Wrapper);
      end if;

      --  This subprogram is referenced, and thus should at least already be
      --  declared. Thus, it must be registered in the environment.

      Result := Env.Get (Subp);

      if not Env.Takes_S_Link (Subp) then
         --  This is a top-level subprogram: wrap it so it can take a static
         --  link as its last argument.

         declare
            Func_Type   : constant Type_T :=
              Get_Element_Type (Type_Of (Result));
            Name        : constant String := Get_Value_Name (Result) & "__CB";
            Return_Type : constant Type_T := Get_Return_Type (Func_Type);
            Args_Count  : constant unsigned :=
              Count_Param_Types (Func_Type) + 1;
            Args        : array (1 .. Args_Count) of Type_T;
         begin
            Get_Param_Types (Func_Type, Args'Address);
            Args (Args'Last) :=
              Pointer_Type (Int8_Type_In_Context (Env.Ctx), 0);
            Result := Add_Function
              (Env.Mdl,
               Name,
               Function_Type
                 (Return_Type,
                  Args'Address, Args'Length,
                  Is_Var_Arg => False));
         end;
      end if;

      Env.Subp_Wrappers.Insert (Subp, Result);
      return Result;
   end Create_Callback_Wrapper;

   ----------------------------------
   -- Attach_Callback_Wrapper_Body --
   ----------------------------------

   procedure Attach_Callback_Wrapper_Body
     (Env : Environ; Subp : Entity_Id; Wrapper : Value_T)
   is
   begin
      if Env.Takes_S_Link (Subp) then
         return;
      end if;

      declare
         BB        : constant Basic_Block_T := Env.Bld.Get_Insert_Block;
         --  Back up the current insert block not to break the caller's
         --  workflow.

         Subp_Spec : constant Node_Id := Parent (Subp);
         Func      : constant Value_T := Emit_Subprogram_Decl (Env, Subp_Spec);
         Func_Type : constant Type_T := Get_Element_Type (Type_Of (Func));

         Call      : Value_T;
         Args      : array (1 .. Count_Param_Types (Func_Type) + 1) of Value_T;
      begin
         Env.Bld.Position_At_End (Append_Basic_Block_In_Context
                                  (Env.Ctx, Wrapper, ""));

         --  The wrapper must call the wrapped function with the same argument
         --  and return its result, if any.

         Get_Params (Wrapper, Args'Address);
         Call := Env.Bld.Call (Func, Args'Address, Args'Length - 1, "");
         if Get_Return_Type (Func_Type) = Void_Type then
            Discard (Env.Bld.Ret_Void);
         else
            Discard (Env.Bld.Ret (Call));
         end if;

         Env.Bld.Position_At_End (BB);
      end;
   end Attach_Callback_Wrapper_Body;

   --------------------------------
   -- Match_Static_Link_Variable --
   --------------------------------

   procedure Match_Static_Link_Variable
     (Env       : Environ;
      Def_Ident : Entity_Id;
      LValue    : Value_T)
   is
      use Defining_Identifier_Vectors;

      Subp   : Subp_Env;
      S_Link : Value_T;
   begin
      --  There is no static link variable to look for if we are at compilation
      --  unit top-level.

      if Env.Current_Subps.Length < 1 then
         return;
      end if;

      Subp := Env.Current_Subp;

      for Cur in Subp.S_Link_Descr.Closure.Iterate loop
         if Element (Cur) = Def_Ident then
            S_Link := Env.Bld.Load (Subp.S_Link, "static-link");
            S_Link := Env.Bld.Insert_Value
              (S_Link,
               LValue,
               unsigned (To_Index (Cur)),
               "updated-static-link");
            Env.Bld.Store (S_Link, Subp.S_Link);
            return;
         end if;
      end loop;
   end Match_Static_Link_Variable;

   ---------------------
   -- Get_Static_Link --
   ---------------------

   function Get_Static_Link
     (Env  : Environ;
      Subp : Entity_Id) return Value_T
   is
      Result_Type : constant Type_T :=
        Pointer_Type (Int8_Type_In_Context (Env.Ctx), 0);
      Result      : Value_T;

      --  In this context, the "caller" is the subprogram that creates an
      --  access to subprogram or that calls directly a subprogram, and the
      --  "caller" is the target subprogram.

      Caller_SLD, Callee_SLD : Static_Link_Descriptor;

      Idx_Type : constant Type_T := Int32_Type_In_Context (Env.Ctx);
      Zero     : constant Value_T := Const_Null (Idx_Type);
      Idx      : constant Value_Array (1 .. 2) := (Zero, Zero);

   begin
      if Env.Takes_S_Link (Subp) then
         Caller_SLD := Env.Current_Subp.S_Link_Descr;
         Callee_SLD := Env.Get_S_Link (Subp);
         Result     := Env.Current_Subp.S_Link;

         --  The language rules force the parent subprogram of the callee to be
         --  the caller or one of its parent.

         while Callee_SLD.Parent /= Caller_SLD loop
            Caller_SLD := Caller_SLD.Parent;
            Result := Env.Bld.Load
              (Env.Bld.GEP (Result, Idx'Address, Idx'Length, ""), "");
         end loop;

         return Env.Bld.Bit_Cast (Result, Result_Type, "");

      else
         --  We end up here for external (and thus top-level) subprograms, so
         --  they take no static link.

         return Const_Null (Result_Type);
      end if;
   end Get_Static_Link;

   ---------------------------
   -- Build_Type_Conversion --
   ---------------------------

   function Build_Type_Conversion
     (Env                 : Environ;
      Src_Type, Dest_Type : Entity_Id;
      Value               : Value_T) return Value_T
   is
   begin
      --  For the moment, we handle only the simple cases of scalar conversions

      if Is_Scalar_Type (Get_Fullest_View (Src_Type))
        and then Is_Scalar_Type (Get_Fullest_View (Dest_Type))
      then
         declare
            Src_LLVM_Type  : constant Type_T := Create_Type (Env, Src_Type);
            Dest_LLVM_Type : constant Type_T := Create_Type (Env, Dest_Type);
            Src_Width      : constant unsigned :=
              Get_Int_Type_Width (Src_LLVM_Type);
            Dest_Width      : constant unsigned :=
              Get_Int_Type_Width (Dest_LLVM_Type);

         begin
            if Src_Width < Dest_Width then
               if Is_Unsigned_Type (Dest_Type) then

                  --  ??? raise an exception if the value is negative (hence
                  --  the source type has to be checked).

                  return Env.Bld.Z_Ext (Value, Dest_LLVM_Type, "int_conv");

               else
                  return Env.Bld.S_Ext (Value, Dest_LLVM_Type, "int_conv");
               end if;

            elsif Src_Width = Dest_Width then
               return Value;

            else
               return Env.Bld.Trunc (Value, Dest_LLVM_Type, "int_conv");
            end if;
         end;

      elsif Is_Descendent_Of_Address (Src_Type)
        and then Is_Descendent_Of_Address (Dest_Type)
      then
         return Env.Bld.Bit_Cast
           (Value,
            Create_Type (Env, Dest_Type),
            "address-conv");

      else
         pragma Annotate (Xcov, Exempt_On, "Defensive programming");
         raise Program_Error with "Unhandled type conv";
         pragma Annotate (Xcov, Exempt_Off);
      end if;
   end Build_Type_Conversion;

   ------------------
   -- Emit_Min_Max --
   ------------------

   function Emit_Min_Max
     (Env         : Environ;
      Exprs       : List_Id;
      Compute_Max : Boolean) return Value_T
   is
      Name      : constant String :=
        (if Compute_Max then "max" else "min");

      Expr_Type : constant Entity_Id := Etype (First (Exprs));
      Left      : constant Value_T := Emit_Expression (Env, First (Exprs));
      Right     : constant Value_T := Emit_Expression (Env, Last (Exprs));

      Comparison_Operators : constant
        array (Boolean, Boolean) of Int_Predicate_T :=
        (True  => (True => Int_UGT, False => Int_ULT),
         False => (True => Int_SGT, False => Int_SLT));
      --  Provide the appropriate scalar comparison operator in order to select
      --  the min/max. First index = is unsigned? Second one = computing max?

      Choose_Left : constant Value_T := Env.Bld.I_Cmp
        (Comparison_Operators (Is_Unsigned_Type (Expr_Type), Compute_Max),
         Left, Right,
         "choose-left-as-" & Name);

   begin
      return Env.Bld.Build_Select (Choose_Left, Left, Right, Name);
   end Emit_Min_Max;

   ------------------------------
   -- Emit_Attribute_Reference --
   ------------------------------

   function Emit_Attribute_Reference
     (Env  : Environ;
      Node : Node_Id) return Value_T
   is
      Attr : constant Attribute_Id := Get_Attribute_Id (Attribute_Name (Node));

   begin
      case Attr is

         when Attribute_Access
            | Attribute_Unchecked_Access
            | Attribute_Unrestricted_Access =>

            --  We store values as pointers, so, getting an access to an
            --  expression is the same thing as getting an LValue, and has
            --  the same constraints.

            return Emit_LValue (Env, Prefix (Node));

         when Attribute_Address =>

            --  Likewise for addresses

            return Env.Bld.Ptr_To_Int
              (Emit_LValue
                 (Env, Prefix (Node)), Get_Address_Type, "to-address");

         when Attribute_First
            | Attribute_Last
            | Attribute_Length =>

            --  Note that there is no need to handle these attributes for
            --  scalar subtypes since the front-end expands them into
            --  constant references.

            declare
               Array_Descr : Value_T;
               Array_Type  : Entity_Id;
            begin
               Extract_Array_Info
                 (Env, Prefix (Node), Array_Descr, Array_Type);
               if Attr = Attribute_Length then
                  return Array_Length (Env, Array_Descr, Array_Type);
               else
                  return Array_Bound
                    (Env, Array_Descr, Array_Type,
                     (if Attr = Attribute_First then Low else High));
               end if;
            end;

         when Attribute_Max
            | Attribute_Min =>
            return Emit_Min_Max
              (Env,
               Expressions (Node),
               Attr = Attribute_Max);

         when Attribute_Succ
            | Attribute_Pred =>
            declare
               Exprs : constant List_Id := Expressions (Node);
               pragma Assert (List_Length (Exprs) = 1);

               Base : constant Value_T := Emit_Expression (Env, First (Exprs));
               T    : constant Type_T := Type_Of (Base);
               pragma Assert (Get_Type_Kind (T) = Integer_Type_Kind);

               One  : constant Value_T :=
                 Const_Int (T, 1, Sign_Extend => False);

            begin
               return
                 (if Attr = Attribute_Succ
                  then Env.Bld.Add (Base, One, "attr-succ")
                  else Env.Bld.Sub (Base, One, "attr-pred"));
            end;

         when others =>
            pragma Annotate (Xcov, Exempt_On, "Defensive programming");
            raise Program_Error
              with "Unhandled Attribute : " & Attribute_Id'Image (Attr);
            pragma Annotate (Xcov, Exempt_Off);
      end case;
   end Emit_Attribute_Reference;

   ---------------------
   -- Emit_Comparison --
   ---------------------

   function Emit_Comparison
     (Env          : Environ;
      Operation    : Pred_Mapping;
      Operand_Type : Entity_Id;
      LHS, RHS     : Node_Id) return Value_T
   is
   begin
      --  LLVM treats pointers as integers regarding comparison

      if Is_Scalar_Type (Operand_Type)
        or else Is_Access_Type (Operand_Type)
      then
         return Env.Bld.I_Cmp
           ((if Is_Unsigned_Type (Operand_Type)
            then Operation.Unsigned
            else Operation.Signed),
            Emit_Expression (Env, LHS),
            Emit_Expression (Env, RHS),
            "icmp");

      elsif Is_Floating_Point_Type (Operand_Type) then
         return Env.Bld.F_Cmp
           (Operation.Real,
            Emit_Expression (Env, LHS),
            Emit_Expression (Env, RHS),
            "fcmp");

      elsif Is_Record_Type (Operand_Type) then
         pragma Annotate (Xcov, Exempt_On, "Defensive programming");
         raise Program_Error
           with "The front-end is supposed to already handle record"
           & " comparisons.";
         pragma Annotate (Xcov, Exempt_Off, "Defensive programming");

      elsif Is_Array_Type (Operand_Type) then
         pragma Assert (Operation.Signed in Int_EQ | Int_NE);

         --  ??? Handle multi-dimensional arrays

         declare
            --  Because of runtime length checks, the comparison is made as
            --  follows:
            --     L_Length <- LHS'Length
            --     R_Length <- RHS'Length
            --     if L_Length /= R_Length then
            --        return False;
            --     elsif L_Length = 0 then
            --        return True;
            --     else
            --        return memory comparison;
            --     end if;
            --  We are generating LLVM IR (SSA form), so the return mechanism
            --  is implemented with control-flow and PHI nodes.

            Bool_Type    : constant Type_T := Int_Ty (1);
            False_Val    : constant Value_T := Const_Int (Bool_Type, 0, False);
            True_Val     : constant Value_T := Const_Int (Bool_Type, 1, False);

            LHS_Descr    : constant Value_T := Emit_LValue (Env, LHS);
            LHS_Type     : constant Entity_Id := Etype (LHS);
            RHS_Descr    : constant Value_T := Emit_LValue (Env, RHS);
            RHS_Type     : constant Entity_Id := Etype (RHS);

            Left_Length  : constant Value_T :=
              Array_Length (Env, LHS_Descr, LHS_Type);
            Right_Length : constant Value_T :=
              Array_Length (Env, RHS_Descr, RHS_Type);
            Null_Length  : constant Value_T :=
              Const_Null (Type_Of (Left_Length));
            Same_Length  : constant Value_T := Env.Bld.I_Cmp
              (Int_NE, Left_Length, Right_Length, "test-same-length");

            Basic_Blocks : constant Basic_Block_Array (1 .. 3) :=
              (Env.Bld.Get_Insert_Block,
               Create_Basic_Block (Env, "when-null-length"),
               Create_Basic_Block (Env, "when-same-length"));
            Results      : Value_Array (1 .. 3);
            BB_Merge     : constant Basic_Block_T :=
              Create_Basic_Block (Env, "array-cmp-merge");
            Phi          : Value_T;

         begin
            Discard (Env.Bld.Cond_Br
                     (C_If   => Same_Length,
                      C_Then => BB_Merge,
                      C_Else => Basic_Blocks (2)));
            Results (1) := False_Val;

            --  If we jump from here to BB_Merge, we are returning False

            Env.Bld.Position_At_End (Basic_Blocks (2));
            Discard (Env.Bld.Cond_Br
                     (C_If   => Env.Bld.I_Cmp
                      (Int_EQ, Left_Length, Null_Length, "test-null-length"),
                      C_Then => BB_Merge,
                      C_Else => Basic_Blocks (3)));
            Results (2) := True_Val;

            --  If we jump from here to BB_Merge, we are returning True

            Env.Bld.Position_At_End (Basic_Blocks (3));
            declare
               Left        : constant Value_T :=
                 Array_Data (Env, LHS_Descr, LHS_Type);
               Right       : constant Value_T :=
                 Array_Data (Env, RHS_Descr, RHS_Type);

               Void_Ptr_Type : constant Type_T := Pointer_Type (Int_Ty (8), 0);
               Size_Type     : constant Type_T := Int_Ty (64);
               Size          : constant Value_T :=
                 Env.Bld.Mul
                   (Env.Bld.Z_Ext (Left_Length, Size_Type, ""),
                    Get_Type_Size
                      (Env, Create_Type (Env, Component_Type (Etype (LHS)))),
                    "byte-size");

               Memcmp_Args : constant Value_Array (1 .. 3) :=
                 (Env.Bld.Bit_Cast (Left, Void_Ptr_Type, ""),
                  Env.Bld.Bit_Cast (Right, Void_Ptr_Type, ""),
                  Size);
               Memcmp      : constant Value_T := Env.Bld.Call
                 (Env.Memory_Cmp_Fn,
                  Memcmp_Args'Address, Memcmp_Args'Length,
                  "");
            begin
               --  The two arrays are equal iff. the call to memcmp returned 0

               Results (3) := Env.Bld.I_Cmp
                 (Operation.Signed,
                  Memcmp,
                  Const_Null (Type_Of (Memcmp)),
                  "array-comparison");
            end;
            Discard (Env.Bld.Br (BB_Merge));

            --  If we jump from here to BB_Merge, we are returning the result
            --  of the memory comparison.

            Env.Bld.Position_At_End (BB_Merge);
            Phi := Env.Bld.Phi (Bool_Type, "");
            Add_Incoming (Phi, Results'Address, Basic_Blocks'Address, 3);
            return Phi;
         end;

      else
         pragma Annotate (Xcov, Exempt_On, "Defensive programming");
         raise Program_Error
           with "Invalid operand type for comparison:"
           & Entity_Kind'Image (Ekind (Operand_Type));
         pragma Annotate (Xcov, Exempt_Off, "Defensive programming");
      end if;
   end Emit_Comparison;

   -------------
   -- Emit_If --
   -------------

   function Emit_If
     (Env  : Environ;
      Node : Node_Id) return Value_T
   is
      Is_Stmt : constant Boolean := Nkind (Node) = N_If_Statement;
      --  Depending on the node to translate, we will have to compute and
      --  return an expression.

      GNAT_Cond : constant Node_Id :=
        (if Is_Stmt
         then Condition (Node)
         else Pick (Expressions (Node), 1));
      Cond      : constant Value_T := Emit_Expression (Env, GNAT_Cond);

      BB_Then, BB_Else, BB_Next : Basic_Block_T;
      --  BB_Then is the basic block we jump to if the condition is true.
      --  BB_Else is the basic block we jump to if the condition is false.
      --  BB_Next is the BB we jump to after the IF is executed.

      Then_Value, Else_Value : Value_T;

   begin
      BB_Next := Create_Basic_Block (Env, "if-next");
      BB_Then := Create_Basic_Block (Env, "if-then");

      --  If this is an IF statement without ELSE part, then we jump to the
      --  BB_Next when the condition is false. Thus, BB_Else and BB_Next
      --  should be the same in this case.

      BB_Else :=
        (if not Is_Stmt or else not Is_Empty_List (Else_Statements (Node))
         then Create_Basic_Block (Env, "if-else")
         else BB_Next);

      Discard (Env.Bld.Cond_Br (Cond, BB_Then, BB_Else));

      --  Emit code for the THEN part

      Env.Bld.Position_At_End (BB_Then);
      if Is_Stmt then
         Emit_List (Env, Then_Statements (Node));
      else
         Then_Value := Emit_Expression (Env, Pick (Expressions (Node), 2));

         --  The THEN part may be composed of multiple basic blocks. We want
         --  to get the one that jumps to the merge point to get the PHI node
         --  predecessor.

         BB_Then := Env.Bld.Get_Insert_Block;
      end if;
      Discard (Env.Bld.Br (BB_Next));

      --  Emit code for the ELSE part

      Env.Bld.Position_At_End (BB_Else);
      if not Is_Stmt then
         Else_Value := Emit_Expression (Env, Pick (Expressions (Node), 3));
         Discard (Env.Bld.Br (BB_Next));

         --  We want to get the basic blocks that jumps to the merge point: see
         --  above.

         BB_Else := Env.Bld.Get_Insert_Block;

      elsif not Is_Empty_List (Else_Statements (Node)) then
         Emit_List (Env, Else_Statements (Node));
         Discard (Env.Bld.Br (BB_Next));
      end if;

      --  Then prepare the instruction builder for the next
      --  statements/expressions and return an merged expression if needed.

      Env.Bld.Position_At_End (BB_Next);
      if Is_Stmt then
         return No_Value_T;

      else
         declare
            Values : constant Value_Array (1 .. 2) :=
              (Then_Value, Else_Value);
            BBs    : constant Basic_Block_Array (1 .. 2) :=
              (BB_Then, BB_Else);
            Phi    : constant Value_T :=
              Env.Bld.Phi (Type_Of (Then_Value), "");
         begin
            Add_Incoming (Phi, Values'Address, BBs'Address, 2);
            return Phi;
         end;
      end if;
   end Emit_If;

   ----------------
   -- Emit_Shift --
   ----------------

   function Emit_Shift
     (Env       : Environ;
      Operation : Node_Kind;
      LHS, RHS  : Value_T) return Value_T
   is
      To_Left, Rotate, Arithmetic : Boolean := False;

      Result   : Value_T := LHS;
      LHS_Type : constant Type_T := Type_Of (LHS);
      N        : Value_T := Env.Bld.S_Ext (RHS, LHS_Type, "bits");
      LHS_Bits : constant Value_T := Const_Int
        (LHS_Type,
         unsigned_long_long (Get_Int_Type_Width (LHS_Type)),
         Sign_Extend => False);

      Saturated  : Value_T;

   begin
      --  Extract properties for the operation we are asked to generate code
      --  for.

      case Operation is
         when N_Op_Shift_Left =>
            To_Left := True;
         when N_Op_Shift_Right =>
            null;
         when N_Op_Shift_Right_Arithmetic =>
            Arithmetic := True;
         when N_Op_Rotate_Left =>
            To_Left := True;
            Rotate := True;
         when N_Op_Rotate_Right =>
            Rotate := True;
         when others =>
            pragma Annotate (Xcov, Exempt_On, "Defensive programming");
            raise Program_Error
              with "Invalid shift/rotate operation: "
              & Node_Kind'Image (Operation);
            pragma Annotate (Xcov, Exempt_Off);
      end case;

      if Rotate then

         --  While LLVM instructions will return an undefined value for
         --  rotations with too many bits, we must handle "multiple turns",
         --  so first get the number of bit to rotate modulo the size of the
         --  operand.

         --  Note that the front-end seems to already compute the modulo, but
         --  just in case...

         N := Env.Bld.U_Rem (N, LHS_Bits, "effective-rotating-bits");

         declare
            --  There is no "rotate" instruction in LLVM, so we have to stick
            --  to shift instructions, just like in C. If we consider that we
            --  are rotating to the left:

            --     Result := (Operand << Bits) | (Operand >> (Size - Bits));
            --               -----------------   --------------------------
            --                    Upper                   Lower

            --  If we are rotating to the right, we switch the direction of the
            --  two shifts.

            Lower_Shift : constant Value_T :=
              Env.Bld.Sub (LHS_Bits, N, "lower-shift");
            Upper       : constant Value_T :=
              (if To_Left
               then Env.Bld.Shl (LHS, N, "rotate-upper")
               else Env.Bld.L_Shr (LHS, N, "rotate-upper"));
            Lower       : constant Value_T :=
              (if To_Left
               then Env.Bld.L_Shr (LHS, Lower_Shift, "rotate-lower")
               else Env.Bld.Shl (LHS, Lower_Shift, "rotate-lower"));

         begin
            return Env.Bld.Build_Or (Upper, Lower, "rotate-result");
         end;

      else
         --  If the number of bits shifted is bigger or equal than the number
         --  of bits in LHS, the underlying LLVM instruction returns an
         --  undefined value, so build what we want ourselves (we call this
         --  a "saturated value").

         Saturated :=
           (if Arithmetic

            --  If we are performing an arithmetic shift, the saturated value
            --  is 0 if LHS is positive, -1 otherwise (in this context, LHS is
            --  always interpreted as a signed integer).

            then Env.Bld.Build_Select
              (C_If   => Env.Bld.I_Cmp
                   (Int_SLT, LHS, Const_Null (LHS_Type), "is-lhs-negative"),
               C_Then => Const_Ones (LHS_Type),
               C_Else => Const_Null (LHS_Type),
               Name   => "saturated")

            else Const_Null (LHS_Type));

         --  Now, compute the value using the underlying LLVM instruction
         Result :=
           (if To_Left
            then Env.Bld.Shl (LHS, N, "shift-left-raw")
            else
              (if Arithmetic
               then Env.Bld.A_Shr (LHS, N, "lshift-right-raw")
               else Env.Bld.L_Shr (LHS, N, "ashift-right-raw")));

         --  Now, we must decide at runtime if it is safe to rely on the
         --  underlying LLVM instruction. If so, use it, otherwise return
         --  the saturated value.

         return Env.Bld.Build_Select
           (C_If   => Env.Bld.I_Cmp (Int_UGE, N, LHS_Bits, "is-saturated"),
            C_Then => Saturated,
            C_Else => Result,
            Name   => "shift-rotate-result");
      end if;
   end Emit_Shift;

end GNATLLVM.Compile;
