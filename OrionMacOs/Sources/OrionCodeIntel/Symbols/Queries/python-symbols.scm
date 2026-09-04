; Python symbol-extraction queries for Orion Phase 1.
; Consumed via Bundle.module by PythonSymbolExtractor (M3). Kept minimal for M0; expanded
; alongside the extractor. Capture names are the contract between this file and Swift.

; --- definitions ---------------------------------------------------------------

(class_definition
  name: (identifier) @class.name) @class.def

(function_definition
  name: (identifier) @function.name) @function.def

(decorated_definition) @decorated.def

; --- imports ------------------------------------------------------------------

(import_statement) @import.stmt

(import_from_statement) @import_from.stmt

(aliased_import
  name: (dotted_name) @import.alias.name
  alias: (identifier) @import.alias.as)

; --- module-level assignments (constants / module vars) ----------------------

(module
  (expression_statement
    (assignment
      left: (identifier) @assign.name))) @assign.stmt
