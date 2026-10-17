package = "dua"
version = "1.0-1"
source = {
   url = "git://github.com/Dua-DSL/dua.lua.git"
}
description = {
   summary = "Domain-Specific Language Engine & Sandbox for Lua",
   detailed = "A lightweight, pure Lua framework for building typed DSLs and sandboxed environments.",
   homepage = "https://github.com/Dua-DSL/dua.lua",
   license = "MIT"
}
dependencies = {
   "lua >= 5.1"
}
build = {
   type = "builtin",
   modules = {
      dua = "dua.lua"
   }
}
