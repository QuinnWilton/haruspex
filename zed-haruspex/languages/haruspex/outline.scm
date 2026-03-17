; Functions
(definition
  "def" @context
  name: (identifier) @name) @item

; Type declarations
(type_declaration
  "type" @context
  name: (type_identifier) @name) @item

; Constructors (nested under types by source position)
(constructor
  name: (identifier) @name) @item

; Record declarations
(record_declaration
  "record" @context
  name: (type_identifier) @name) @item

; Record fields (nested under records by source position)
(field_declaration
  name: (identifier) @name) @item

; Class declarations
(class_declaration
  "class" @context
  name: (type_identifier) @name) @item

; Method signatures (nested under classes by source position)
(method_signature
  name: (identifier) @name) @item

; Instance declarations
(instance_declaration
  "instance" @context
  class_name: (type_identifier) @name) @item
