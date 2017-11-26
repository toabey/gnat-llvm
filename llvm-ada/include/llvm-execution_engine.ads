pragma Ada_2005;
pragma Style_Checks (Off);

pragma Warnings (Off); with Interfaces.C; use Interfaces.C; pragma Warnings (On);
with System;
with LLVM.Target_Machine;
with LLVM.Types;
with Interfaces.C.Extensions;
with stddef_h;
with Interfaces.C.Strings;
with LLVM.Target;
with stdint_h;

package LLVM.Execution_Engine is

   procedure Link_In_MCJIT;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:37
   pragma Import (C, Link_In_MCJIT, "LLVMLinkInMCJIT");

   procedure Link_In_Interpreter;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:38
   pragma Import (C, Link_In_Interpreter, "LLVMLinkInInterpreter");

   --  skipped empty struct LLVMOpaqueGenericValue

   type Generic_Value_T is new System.Address;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:40

   --  skipped empty struct LLVMOpaqueExecutionEngine

   type Execution_Engine_T is new System.Address;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:41

   --  skipped empty struct LLVMOpaqueMCJITMemoryManager

   type MCJIT_Memory_Manager_T is new System.Address;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:42

   type MCJIT_Compiler_Options_T is record
      OptLevel : aliased unsigned;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:45
      CodeModel : aliased LLVM.Target_Machine.Code_Model_T;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:46
      NoFramePointerElim : aliased LLVM.Types.Bool_T;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:47
      EnableFastISel : aliased LLVM.Types.Bool_T;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:48
      MCJMM : MCJIT_Memory_Manager_T;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:49
   end record;
   pragma Convention (C_Pass_By_Copy, MCJIT_Compiler_Options_T);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:44

function Create_Generic_Value_Of_Int
     (Ty        : LLVM.Types.Type_T;
      N         : Extensions.unsigned_long_long;
      Is_Signed : Boolean)
      return Generic_Value_T;
   function Create_Generic_Value_Of_Int_C
     (Ty        : LLVM.Types.Type_T;
      N         : Extensions.unsigned_long_long;
      Is_Signed : LLVM.Types.Bool_T)
      return Generic_Value_T;
   pragma Import (C, Create_Generic_Value_Of_Int_C, "LLVMCreateGenericValueOfInt");

   function Create_Generic_Value_Of_Pointer (P : System.Address) return Generic_Value_T;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:58
   pragma Import (C, Create_Generic_Value_Of_Pointer, "LLVMCreateGenericValueOfPointer");

   function Create_Generic_Value_Of_Float (Ty : LLVM.Types.Type_T; N : double) return Generic_Value_T;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:60
   pragma Import (C, Create_Generic_Value_Of_Float, "LLVMCreateGenericValueOfFloat");

   function Generic_Value_Int_Width (Gen_Val_Ref : Generic_Value_T) return unsigned;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:62
   pragma Import (C, Generic_Value_Int_Width, "LLVMGenericValueIntWidth");

   function Generic_Value_To_Int
     (Gen_Val   : Generic_Value_T;
      Is_Signed : Boolean)
      return Extensions.unsigned_long_long;
   function Generic_Value_To_Int_C
     (Gen_Val   : Generic_Value_T;
      Is_Signed : LLVM.Types.Bool_T)
      return Extensions.unsigned_long_long;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:64
   pragma Import (C, Generic_Value_To_Int_C, "LLVMGenericValueToInt");

   function Generic_Value_To_Pointer (Gen_Val : Generic_Value_T) return System.Address;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:67
   pragma Import (C, Generic_Value_To_Pointer, "LLVMGenericValueToPointer");

   function Generic_Value_To_Float (Ty_Ref : LLVM.Types.Type_T; Gen_Val : Generic_Value_T) return double;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:69
   pragma Import (C, Generic_Value_To_Float, "LLVMGenericValueToFloat");

   procedure Dispose_Generic_Value (Gen_Val : Generic_Value_T);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:71
   pragma Import (C, Dispose_Generic_Value, "LLVMDisposeGenericValue");

function Create_Execution_Engine_For_Module
     (Out_EE    : System.Address;
      M         : LLVM.Types.Module_T;
      Out_Error : System.Address)
      return Boolean;
   function Create_Execution_Engine_For_Module_C
     (Out_EE    : System.Address;
      M         : LLVM.Types.Module_T;
      Out_Error : System.Address)
      return LLVM.Types.Bool_T;
   pragma Import (C, Create_Execution_Engine_For_Module_C, "LLVMCreateExecutionEngineForModule");

function Create_Interpreter_For_Module
     (Out_Interp : System.Address;
      M          : LLVM.Types.Module_T;
      Out_Error  : System.Address)
      return Boolean;
   function Create_Interpreter_For_Module_C
     (Out_Interp : System.Address;
      M          : LLVM.Types.Module_T;
      Out_Error  : System.Address)
      return LLVM.Types.Bool_T;
   pragma Import (C, Create_Interpreter_For_Module_C, "LLVMCreateInterpreterForModule");

function Create_JIT_Compiler_For_Module
     (Out_JIT   : System.Address;
      M         : LLVM.Types.Module_T;
      Opt_Level : unsigned;
      Out_Error : System.Address)
      return Boolean;
   function Create_JIT_Compiler_For_Module_C
     (Out_JIT   : System.Address;
      M         : LLVM.Types.Module_T;
      Opt_Level : unsigned;
      Out_Error : System.Address)
      return LLVM.Types.Bool_T;
   pragma Import (C, Create_JIT_Compiler_For_Module_C, "LLVMCreateJITCompilerForModule");

   procedure Initialize_MCJIT_Compiler_Options (Options : access MCJIT_Compiler_Options_T; Size_Of_Options : stddef_h.size_t);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:88
   pragma Import (C, Initialize_MCJIT_Compiler_Options, "LLVMInitializeMCJITCompilerOptions");

function Create_MCJIT_Compiler_For_Module
     (Out_JIT         : System.Address;
      M               : LLVM.Types.Module_T;
      Options         : MCJIT_Compiler_Options_T;
      Size_Of_Options : stddef_h.size_t;
      Out_Error       : System.Address)
      return Boolean;
   function Create_MCJIT_Compiler_For_Module_C
     (Out_JIT         : System.Address;
      M               : LLVM.Types.Module_T;
      Options         : MCJIT_Compiler_Options_T;
      Size_Of_Options : stddef_h.size_t;
      Out_Error       : System.Address)
      return LLVM.Types.Bool_T;
   pragma Import (C, Create_MCJIT_Compiler_For_Module_C, "LLVMCreateMCJITCompilerForModule");

   procedure Dispose_Execution_Engine (EE : Execution_Engine_T);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:113
   pragma Import (C, Dispose_Execution_Engine, "LLVMDisposeExecutionEngine");

   procedure Run_Static_Constructors (EE : Execution_Engine_T);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:115
   pragma Import (C, Run_Static_Constructors, "LLVMRunStaticConstructors");

   procedure Run_Static_Destructors (EE : Execution_Engine_T);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:117
   pragma Import (C, Run_Static_Destructors, "LLVMRunStaticDestructors");

   function Run_Function_As_Main
     (EE : Execution_Engine_T;
      F : LLVM.Types.Value_T;
      Arg_C : unsigned;
      Arg_V : System.Address;
      Env_P : System.Address) return int;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:119
   pragma Import (C, Run_Function_As_Main, "LLVMRunFunctionAsMain");

   function Run_Function
     (EE : Execution_Engine_T;
      F : LLVM.Types.Value_T;
      Num_Args : unsigned;
      Args : System.Address) return Generic_Value_T;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:123
   pragma Import (C, Run_Function, "LLVMRunFunction");

   procedure Free_Machine_Code_For_Function (EE : Execution_Engine_T; F : LLVM.Types.Value_T);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:127
   pragma Import (C, Free_Machine_Code_For_Function, "LLVMFreeMachineCodeForFunction");

   procedure Add_Module (EE : Execution_Engine_T; M : LLVM.Types.Module_T);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:129
   pragma Import (C, Add_Module, "LLVMAddModule");

function Remove_Module
     (EE        : Execution_Engine_T;
      M         : LLVM.Types.Module_T;
      Out_Mod   : System.Address;
      Out_Error : System.Address)
      return Boolean;
   function Remove_Module_C
     (EE        : Execution_Engine_T;
      M         : LLVM.Types.Module_T;
      Out_Mod   : System.Address;
      Out_Error : System.Address)
      return LLVM.Types.Bool_T;
   pragma Import (C, Remove_Module_C, "LLVMRemoveModule");

function Find_Function
     (EE     : Execution_Engine_T;
      Name   : String;
      Out_Fn : System.Address)
      return Boolean;
   function Find_Function_C
     (EE     : Execution_Engine_T;
      Name   : Interfaces.C.Strings.chars_ptr;
      Out_Fn : System.Address)
      return LLVM.Types.Bool_T;
   pragma Import (C, Find_Function_C, "LLVMFindFunction");

   function Recompile_And_Relink_Function (EE : Execution_Engine_T; Fn : LLVM.Types.Value_T) return System.Address;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:137
   pragma Import (C, Recompile_And_Relink_Function, "LLVMRecompileAndRelinkFunction");

   function Get_Execution_Engine_Target_Data (EE : Execution_Engine_T) return LLVM.Target.Target_Data_T;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:140
   pragma Import (C, Get_Execution_Engine_Target_Data, "LLVMGetExecutionEngineTargetData");

   function Get_Execution_Engine_Target_Machine (EE : Execution_Engine_T) return LLVM.Target_Machine.Target_Machine_T;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:142
   pragma Import (C, Get_Execution_Engine_Target_Machine, "LLVMGetExecutionEngineTargetMachine");

   procedure Add_Global_Mapping
     (EE : Execution_Engine_T;
      Global : LLVM.Types.Value_T;
      Addr : System.Address);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:144
   pragma Import (C, Add_Global_Mapping, "LLVMAddGlobalMapping");

   function Get_Pointer_To_Global (EE : Execution_Engine_T; Global : LLVM.Types.Value_T) return System.Address;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:147
   pragma Import (C, Get_Pointer_To_Global, "LLVMGetPointerToGlobal");

   function Get_Global_Value_Address
     (EE   : Execution_Engine_T;
      Name : String)
      return stdint_h.uint64_t;
   function Get_Global_Value_Address_C
     (EE   : Execution_Engine_T;
      Name : Interfaces.C.Strings.chars_ptr)
      return stdint_h.uint64_t;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:149
   pragma Import (C, Get_Global_Value_Address_C, "LLVMGetGlobalValueAddress");

   function Get_Function_Address
     (EE   : Execution_Engine_T;
      Name : String)
      return stdint_h.uint64_t;
   function Get_Function_Address_C
     (EE   : Execution_Engine_T;
      Name : Interfaces.C.Strings.chars_ptr)
      return stdint_h.uint64_t;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:151
   pragma Import (C, Get_Function_Address_C, "LLVMGetFunctionAddress");

   type Memory_Manager_Allocate_Code_Section_Callback_T is access function 
        (arg1 : System.Address;
         arg2 : stdint_h.uintptr_t;
         arg3 : unsigned;
         arg4 : unsigned;
         arg5 : Interfaces.C.Strings.chars_ptr) return access stdint_h.uint8_t;
   pragma Convention (C, Memory_Manager_Allocate_Code_Section_Callback_T);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:155

   type Memory_Manager_Allocate_Data_Section_Callback_T is access function 
        (arg1 : System.Address;
         arg2 : stdint_h.uintptr_t;
         arg3 : unsigned;
         arg4 : unsigned;
         arg5 : Interfaces.C.Strings.chars_ptr;
         arg6 : LLVM.Types.Bool_T) return access stdint_h.uint8_t;
   pragma Convention (C, Memory_Manager_Allocate_Data_Section_Callback_T);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:158

   type Memory_Manager_Finalize_Memory_Callback_T is access function  (arg1 : System.Address; arg2 : System.Address) return LLVM.Types.Bool_T;
   pragma Convention (C, Memory_Manager_Finalize_Memory_Callback_T);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:161

   type Memory_Manager_Destroy_Callback_T is access procedure  (arg1 : System.Address);
   pragma Convention (C, Memory_Manager_Destroy_Callback_T);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:163

   function Create_Simple_MCJIT_Memory_Manager
     (Opaque : System.Address;
      Allocate_Code_Section : Memory_Manager_Allocate_Code_Section_Callback_T;
      Allocate_Data_Section : Memory_Manager_Allocate_Data_Section_Callback_T;
      Finalize_Memory : Memory_Manager_Finalize_Memory_Callback_T;
      Destroy : Memory_Manager_Destroy_Callback_T) return MCJIT_Memory_Manager_T;  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:176
   pragma Import (C, Create_Simple_MCJIT_Memory_Manager, "LLVMCreateSimpleMCJITMemoryManager");

   procedure Dispose_MCJIT_Memory_Manager (MM : MCJIT_Memory_Manager_T);  -- /chelles.b/users/charlet/git/gnat-llvm/llvm-ada/llvm-5.0.0.src/include/llvm-c/ExecutionEngine.h:183
   pragma Import (C, Dispose_MCJIT_Memory_Manager, "LLVMDisposeMCJITMemoryManager");

end LLVM.Execution_Engine;

