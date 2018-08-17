------------------------------------------------------------------------------
--                             G N A T - L L V M                            --
--                                                                          --
--                     Copyright (C) 2013-2018, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with System;

with stdint_h;

with Interfaces.C;
with Interfaces.C.Extensions;

with Atree; use Atree;
with Einfo; use Einfo;
with Namet; use Namet;
with Types; use Types;

with LLVM.Target;         use LLVM.Target;
with LLVM.Target_Machine; use LLVM.Target_Machine;
with LLVM.Types;          use LLVM.Types;

package GNATLLVM is

   --  This package contains very low-level types, objects, and functions,
   --  mostly corresponding to LLVM objects and exists to avoid circular
   --  dependencies between other specs.  The intent is that every child
   --  package of LLVM with's this child, but that this with's no other
   --  children.

   --  Define unsigned and unsigned_long_long here instead of use'ing
   --  Interfaces.C and Interfaces.C.Extensions because the latter brings
   --  in a lot of junk that gets in the way and the former conflicts with
   --  Int from the front end.

   subtype unsigned is Interfaces.C.unsigned;
   function "+" (L, R : unsigned)  return unsigned renames Interfaces.C."+";
   function "-" (L, R : unsigned)  return unsigned renames Interfaces.C."-";
   function "*" (L, R : unsigned)  return unsigned renames Interfaces.C."*";
   function "/" (L, R : unsigned)  return unsigned renames Interfaces.C."/";
   function "=" (L, R : unsigned)  return Boolean  renames Interfaces.C."=";
   function ">" (L, R : unsigned)  return Boolean  renames Interfaces.C.">";
   function "<" (L, R : unsigned)  return Boolean  renames Interfaces.C."<";
   function "<=" (L, R : unsigned) return Boolean  renames Interfaces.C."<=";
   function ">=" (L, R : unsigned) return Boolean  renames Interfaces.C.">=";

   subtype unsigned_long_long is Interfaces.C.Extensions.unsigned_long_long;
   subtype ULL is unsigned_long_long;
   --  Define shorter alias name for easier reading

   function "+"  (L, R : ULL)  return ULL renames Interfaces.C.Extensions."+";
   function "-"  (L, R : ULL)  return ULL renames Interfaces.C.Extensions."-";
   function "*"  (L, R : ULL)  return ULL renames Interfaces.C.Extensions."*";
   function "/"  (L, R : ULL)  return ULL renames Interfaces.C.Extensions."/";

   function "="  (L, R : ULL)  return Boolean
     renames Interfaces.C.Extensions."=";
   function ">"  (L, R : ULL)  return Boolean
     renames Interfaces.C.Extensions.">";
   function "<"  (L, R : ULL)  return Boolean renames
     Interfaces.C.Extensions."<";
   function "<=" (L, R : ULL) return  Boolean renames
     Interfaces.C.Extensions."<=";
   function ">=" (L, R : ULL) return  Boolean renames
     Interfaces.C.Extensions.">=";

   type MD_Builder_T is new System.Address;
   --  Metadata builder type: opaque for us

   type Value_Array        is array (Nat range <>) of Value_T;
   type Basic_Block_Array  is array (Nat range <>) of Basic_Block_T;
   type Access_Value_Array is access all Value_Array;

   No_Value_T    : constant Value_T       := Value_T (System.Null_Address);
   No_Type_T     : constant Type_T        := Type_T (System.Null_Address);
   No_BB_T       : constant Basic_Block_T :=
     Basic_Block_T (System.Null_Address);
   No_Metadata_T : constant Metadata_T    := Metadata_T (System.Null_Address);
   No_Builder_T  : constant Builder_T     := Builder_T (System.Null_Address);
   --  Constant for null objects of various types

   function No (V : Value_T)            return Boolean is (V = No_Value_T);
   function No (T : Type_T)             return Boolean is (T = No_Type_T);
   function No (B : Basic_Block_T)      return Boolean is (B = No_BB_T);
   function No (M : Metadata_T)         return Boolean is (M = No_Metadata_T);
   function No (M : Builder_T)          return Boolean is (M = No_Builder_T);
   function No (N : Name_Id)            return Boolean is (N = No_Name);

   function Present (V : Value_T)       return Boolean is (V /= No_Value_T);
   function Present (T : Type_T)        return Boolean is (T /= No_Type_T);
   function Present (B : Basic_Block_T) return Boolean is (B /= No_BB_T);
   function Present (M : Metadata_T)    return Boolean is (M /= No_Metadata_T);
   function Present (M : Builder_T)     return Boolean is (M /= No_Builder_T);
   function Present (N : Name_Id)       return Boolean is (N /= No_Name);
   --  Test for presence and absence of fields of LLVM types

   function Is_Type_Or_Void (E : Entity_Id) return Boolean is
     (Ekind (E) = E_Void or else Is_Type (E));
   --  We can have Etype's that are E_Void for E_Procedure

   type Word_Array is array (Nat range <>) of aliased stdint_h.uint64_t;
   --  Array of words for LLVM construction functions

   Context            : Context_T;
   --  The current LLVM Context

   IR_Builder         : Builder_T;
   --  The current LLVM Instruction builder

   DI_Builder          : DI_Builder_T;
   --  The current LLVM Debug Info builder

   Module             : Module_T;
   --  The LLVM Module being compiled

   LLVM_Target        : Target_T;
   --  The LLVM target for our module

   Target_Machine     : Target_Machine_T;
   --  The LLVM target machine for our module

   MD_Builder         : MD_Builder_T;
   --  The current LLVM Metadata builder

   TBAA_Root          : Metadata_T;
   --  Root of tree for Type-Based alias Analysis (TBAA) metadata

   Module_Data_Layout : Target_Data_T;
   --  LLVM current module data layout.

   Size_Type          : Entity_Id;
   LLVM_Size_Type     : Type_T;
   --  Types to use for sizes

   Void_Ptr_Type      : Type_T;
   --  Pointer to arbitrary memory (we use i8 *); equivalent of
   --  Standard_A_Char.

   Int_32_Type        : Entity_Id;
   --  GNAT type for 32-bit integers (for GEP indexes)

   --  GNAT LLVM switches

   Output_Assembly : Boolean := False;
   --  True if -S was specified

   Emit_LLVM       : Boolean := False;
   --  True if -emit-llvm was specified

   Emit_Debug_Info : Boolean := False;
   --  Whether or not to emit debugging information (-g)

   Do_Stack_Check : Boolean := False;
   --  If set, check for too-large allocation

   subtype Err_Msg_Type is String (1 .. 10000);
   type Ptr_Err_Msg_Type is access all Err_Msg_Type;
   --  Used for LLVM error handling

   function Get_LLVM_Error_Msg (Msg : Ptr_Err_Msg_Type) return String;
   --  Get the LLVM error message that was stored in Msg

end GNATLLVM;
