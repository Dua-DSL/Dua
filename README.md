# Dua

**Domain-Specific Language Engine & Sandbox**

<p>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <a href="https://www.lua.org"><img src="https://img.shields.io/badge/Lua-5.1%20%7C%205.2%20%7C%205.3%20%7C%205.4%20%7C%20LuaJIT-purple.svg" alt="Lua Versions"></a>
</p>

---

## Specifications

* **File Name**: `dua.lua`
* **Version**: `Dua 1.0`
* **Core Object**: `Dua`
* **Dependencies**: Zero external dependencies (Pure Lua)
* **Compatibility**: Lua 5.1+, LuaJIT

---

## Architecture & Components

* **Error Handling**: `Error` module with source and line tracking
* **Symbols**: `Dua.symbol` for identifier pooling
* **Type System (`T`)**: 
  * Primitives: `any`, `string`, `number`, `integer`, `boolean`, `table`, `func`
  * Advanced: `node`, `enum`, `literal`, `oneof`, `list`, `map`, `shape`, `custom`
* **AST & Nodes**: `NodeMT`, `NodeMethods` (hierarchical tree traversal, validation)
* **Documents**: `DocMT`, `DocMethods` (settings, roots, serialization)
* **Serialization**: `Dua.serialize` for converting tables/AST back to Lua code

---

## Language Definition API (`Language`)

* **Schema Building**: `node`, `nodes`, `tags`, `setting`, `property`, `settings`, `properties`
* **Constants & Functions**: `const`, `consts`, `func`, `funcs`, `symbols`, `alias`
* **Security & Sandboxing**: `allow`, `allow_all`, `deny`, `unknown`, `assignments`
* **Limits & Hooks**: `limit`, `operator`, `hook`, `extend`

---

## Compilation & Execution

* `Language:compile(src, name)`
* `Language:run(src, opts)`
* `Language:compile_file(path)`
* `Language:run_file(path, opts)`
* `ScriptMethods.run(opts)`

---

## License

MIT License
