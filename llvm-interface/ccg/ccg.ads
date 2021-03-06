------------------------------------------------------------------------------
--                              C C G                                       --
--                                                                          --
--                     Copyright (C) 2013-2020, AdaCore                     --
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

with Interfaces.C;

with LLVM.Types; use LLVM.Types;

with Types; use Types;

package CCG is

   subtype unsigned is Interfaces.C.unsigned;

   --  This package and its children generate C code from the LLVM IR
   --  generated by GNAT LLLVM.

   procedure Initialize_C_Writing;
   --  Do any initialization needed to write C.  This is always called after
   --  we've obtained target parameters.

   procedure Write_C_Code (Module : Module_T);
   --  The main procedure, which generates C code from the LLVM IR

   --  Define the sizes of all the basic C types.

   Char_Size      : Pos;
   Short_Size     : Pos;
   Int_Size       : Pos;
   Long_Size      : Pos;
   Long_Long_Size : Pos;

end CCG;
