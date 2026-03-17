; Keywords
[
  "def"
  "do"
  "end"
  "type"
  "case"
  "fn"
  "let"
  "if"
  "else"
  "import"
  "mutual"
  "class"
  "instance"
  "record"
  "with"
] @keyword

; Annotation keywords
(annotation) @attribute

(no_prelude) @attribute

(protocol_annotation) @attribute

(implicit_declaration
  "@" @attribute
  "implicit" @attribute)

; Function names in definitions
(definition
  name: (identifier) @function)

; Method signatures in class bodies
(method_signature
  name: (identifier) @function)

; Function application
(application
  function: (variable (identifier) @function.call))

; Type names (uppercase identifiers)
(type_variable (type_identifier) @type)

(type_declaration
  name: (type_identifier) @type)

(record_declaration
  name: (type_identifier) @type)

(class_declaration
  name: (type_identifier) @type)

(instance_declaration
  class_name: (type_identifier) @type)

(module_path
  (type_identifier) @type)

(type_universe) @type.builtin

; Constructor names
(constructor
  name: (identifier) @constructor)

(constructor_pattern
  name: (identifier) @constructor)

(constructor_pattern
  name: (type_identifier) @constructor)

; Variables
(variable (identifier) @variable)

; Parameter names
(parameter
  name: (identifier) @variable.parameter)

(implicit_parameter
  name: (identifier) @variable.parameter)

(instance_parameter
  name: (identifier) @variable.parameter)

(type_parameter
  name: (identifier) @variable.parameter)

; Field names
(field_declaration
  name: (identifier) @property)

(field_assignment
  name: (identifier) @property)

(field_pattern
  name: (identifier) @property)

(dot_expression
  field: (identifier) @property)

; Operators
[
  "+"
  "-"
  "*"
  "/"
  "=="
  "!="
  "<"
  ">"
  "<="
  ">="
  "&&"
  "||"
  "not"
  "->"
  "|>"
  "|"
  "="
  ":"
  "."
  "%"
] @operator

; Number literals
(integer) @number
(float) @number.float

; String literals
(string) @string
(escape_sequence) @string.escape

; Atom literals
(atom) @constant

; Boolean literals
(boolean) @constant.builtin

; Hole / wildcard
(hole) @variable.builtin
(wildcard_pattern) @variable.builtin

; Multiplicity annotation (erasure marker)
(multiplicity) @attribute

; Comments
(comment) @comment

; Punctuation — brackets
[
  "("
  ")"
  "{"
  "}"
  "["
  "]"
] @punctuation.bracket

; Punctuation — delimiters
[
  ","
] @punctuation.delimiter
