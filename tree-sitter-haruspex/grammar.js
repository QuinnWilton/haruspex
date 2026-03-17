/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

// Precedence levels matching the Pratt parser in parser.ex.
// Higher number = tighter binding.
const PREC = {
  ARROW: 1,      // -> (right-assoc)
  PIPE: 2,       // |> (left-assoc)
  OR: 3,         // || (left-assoc)
  AND: 4,        // && (left-assoc)
  EQUALITY: 5,   // == != (left-assoc)
  COMPARISON: 6, // < > <= >= (left-assoc)
  ADDITION: 7,   // + - (left-assoc)
  MULTIPLY: 8,   // * / (left-assoc)
  UNARY: 9,      // - not (prefix)
  APPLICATION: 10, // f(x) (left)
  DOT: 11,       // expr.field (left)
  ANNOTATION: 12, // : type (for inline annotations)
};

module.exports = grammar({
  name: "haruspex",

  extras: $ => [
    /\s/,
    $.comment,
  ],

  word: $ => $.identifier,

  conflicts: $ => [
    [$.sigma_type, $.variable],
    [$.parenthesized_expression, $.application],
  ],

  rules: {
    source_file: $ => repeat($._toplevel),

    // ========================================================================
    // Top-level declarations
    // ========================================================================

    _toplevel: $ => choice(
      $.definition,
      $.type_declaration,
      $.record_declaration,
      $.import_declaration,
      $.mutual_block,
      $.class_declaration,
      $.instance_declaration,
      $.implicit_declaration,
      $.no_prelude,
    ),

    // ========================================================================
    // Annotations
    // ========================================================================

    annotation: $ => seq(
      "@",
      choice(
        "total",
        "private",
        $.extern_annotation,
        $.fuel_annotation,
      ),
    ),

    extern_annotation: $ => seq(
      "extern",
      $.extern_ref,
    ),

    // Extern references: Module.func/arity or :erlang_mod.func/arity
    // Flattened to avoid dot-separation ambiguity. The last dot-separated
    // lowercase identifier is the function name; everything before it is the module.
    extern_ref: $ => /[A-Z][a-zA-Z0-9_]*(\.[A-Z][a-zA-Z0-9_]*)*\.[a-z_][a-zA-Z0-9_]*\/[0-9]+/,

    fuel_annotation: $ => seq(
      "fuel",
      $.integer,
    ),

    no_prelude: $ => seq("@", "no_prelude"),

    protocol_annotation: $ => seq("@", "protocol"),

    // ========================================================================
    // Definitions
    // ========================================================================

    definition: $ => seq(
      repeat($.annotation),
      "def",
      field("name", $.identifier),
      optional($.parameter_list),
      optional($.return_type),
      optional($.do_block),
    ),

    return_type: $ => seq(":", $._expression),

    do_block: $ => seq("do", optional($._block_body), "end"),

    _block_body: $ => $._expression,

    // ========================================================================
    // Parameters
    // ========================================================================

    parameter_list: $ => seq(
      "(",
      optional(seq(
        $._parameter,
        repeat(seq(",", $._parameter)),
        optional(","),
      )),
      ")",
    ),

    _parameter: $ => choice(
      $.implicit_parameter,
      $.instance_parameter,
      $.parameter,
    ),

    parameter: $ => seq(
      optional($.multiplicity),
      field("name", choice($.identifier, "_")),
      ":",
      field("type", $._expression),
    ),

    implicit_parameter: $ => seq(
      "{",
      optional($.multiplicity),
      field("name", choice($.identifier, "_")),
      ":",
      field("type", $._expression),
      "}",
    ),

    instance_parameter: $ => seq(
      "[",
      field("name", choice($.identifier, "_")),
      ":",
      field("type", $._expression),
      "]",
    ),

    multiplicity: $ => "0",

    // ========================================================================
    // Type declarations
    // ========================================================================

    type_declaration: $ => seq(
      "type",
      field("name", $.type_identifier),
      optional($.type_parameter_list),
      "=",
      optional("|"),
      $.constructor,
      repeat(seq("|", $.constructor)),
    ),

    type_parameter_list: $ => seq(
      "(",
      $.type_parameter,
      repeat(seq(",", $.type_parameter)),
      optional(","),
      ")",
    ),

    type_parameter: $ => seq(
      field("name", $.identifier),
      ":",
      field("kind", $._expression),
    ),

    constructor: $ => seq(
      field("name", choice($.identifier, "true", "false")),
      optional($.constructor_args),
      optional($.constructor_return_type),
    ),

    constructor_args: $ => seq(
      "(",
      optional(seq(
        $._expression,
        repeat(seq(",", $._expression)),
        optional(","),
      )),
      ")",
    ),

    constructor_return_type: $ => seq(":", $._expression),

    // ========================================================================
    // Record declarations
    // ========================================================================

    record_declaration: $ => seq(
      "record",
      field("name", $.type_identifier),
      optional($.parameter_list),
      ":",
      $.field_declaration,
      repeat(seq(",", $.field_declaration)),
    ),

    field_declaration: $ => seq(
      field("name", $.identifier),
      ":",
      field("type", $._expression),
    ),

    // ========================================================================
    // Import declarations
    // ========================================================================

    import_declaration: $ => seq(
      "import",
      $._module_path,
      optional($.import_options),
    ),

    import_options: $ => seq(
      ",",
      "open",
      ":",
      choice(
        "true",
        $.import_name_list,
      ),
    ),

    import_name_list: $ => seq(
      "[",
      optional(seq(
        $.identifier,
        repeat(seq(",", $.identifier)),
      )),
      "]",
    ),

    _module_path: $ => choice(
      $.module_path,
      $.atom,
    ),

    module_path: $ => seq(
      $.type_identifier,
      repeat(seq(".", $.type_identifier)),
    ),

    // ========================================================================
    // Mutual blocks
    // ========================================================================

    mutual_block: $ => seq(
      "mutual",
      "do",
      repeat($._toplevel),
      "end",
    ),

    // ========================================================================
    // Class and instance declarations
    // ========================================================================

    class_declaration: $ => seq(
      optional($.protocol_annotation),
      "class",
      field("name", $.type_identifier),
      optional($.parameter_list),
      optional($.constraint_list),
      "do",
      repeat($.method_signature),
      "end",
    ),

    constraint_list: $ => seq(
      "[",
      $.constraint,
      repeat(seq(",", $.constraint)),
      "]",
    ),

    constraint: $ => seq(
      $.type_identifier,
      optional(seq(
        "(",
        optional(seq(
          $._expression,
          repeat(seq(",", $._expression)),
        )),
        ")",
      )),
    ),

    method_signature: $ => seq(
      field("name", $.identifier),
      ":",
      field("type", $._expression),
    ),

    instance_declaration: $ => seq(
      "instance",
      field("class_name", $.type_identifier),
      optional(seq(
        "(",
        optional(seq(
          $._expression,
          repeat(seq(",", $._expression)),
        )),
        ")",
      )),
      optional($.constraint_list),
      "do",
      repeat($.definition),
      "end",
    ),

    // ========================================================================
    // Implicit declarations
    // ========================================================================

    implicit_declaration: $ => seq(
      "@",
      "implicit",
      repeat1($.implicit_parameter),
    ),

    // ========================================================================
    // Expressions
    // ========================================================================

    _expression: $ => choice(
      $.variable,
      $.type_variable,
      $.type_universe,
      $._literal,
      $.hole,
      $.parenthesized_expression,
      $.binary_expression,
      $.unary_expression,
      $.application,
      $.lambda,
      $.case_expression,
      $.with_expression,
      $.let_expression,
      $.if_expression,
      $.pipe_expression,
      $.arrow_expression,
      $.dot_expression,
      $.annotation_expression,
      $.sigma_type,
      $.refinement_type,
      $.implicit_binder,
      $.record_expression,
      $.record_update,
    ),

    // Parenthesized expression (grouping) or tuple.
    parenthesized_expression: $ => seq(
      "(",
      $._expression,
      optional(seq(",", $._expression, repeat(seq(",", $._expression)))),
      ")",
    ),

    // Type annotation: (expr : type)
    annotation_expression: $ => prec(PREC.ANNOTATION, seq(
      "(",
      $._expression,
      ":",
      $._expression,
      ")",
    )),

    // Sigma type: (name : type, type)
    sigma_type: $ => seq(
      "(",
      field("name", $.identifier),
      ":",
      field("fst_type", $._expression),
      ",",
      field("snd_type", $._expression),
      ")",
    ),

    // Refinement type: {x : T | P}
    refinement_type: $ => seq(
      "{",
      field("name", $.identifier),
      ":",
      field("type", $._expression),
      "|",
      field("predicate", $._expression),
      "}",
    ),

    // Implicit binder: {x : T}
    implicit_binder: $ => seq(
      "{",
      optional($.multiplicity),
      field("name", $.identifier),
      ":",
      field("type", $._expression),
      "}",
    ),

    // Record construction: %Point{x: 1, y: 2}
    record_expression: $ => seq(
      "%",
      field("type", $.type_identifier),
      "{",
      optional(seq(
        $.field_assignment,
        repeat(seq(",", $.field_assignment)),
        optional(","),
      )),
      "}",
    ),

    field_assignment: $ => seq(
      field("name", $.identifier),
      ":",
      field("value", $._expression),
    ),

    // Record update: %Point{p | x: 3} or %{p | x: 3}
    record_update: $ => choice(
      seq(
        "%",
        field("type", $.type_identifier),
        "{",
        field("target", $._expression),
        "|",
        $.field_assignment,
        repeat(seq(",", $.field_assignment)),
        "}",
      ),
      seq(
        "%",
        "{",
        field("target", $._expression),
        "|",
        $.field_assignment,
        repeat(seq(",", $.field_assignment)),
        "}",
      ),
    ),

    // Arrow type: A -> B (right-associative)
    arrow_expression: $ => prec.right(PREC.ARROW, seq(
      field("domain", $._expression),
      "->",
      field("codomain", $._expression),
    )),

    // Pipe: a |> b (left-associative)
    pipe_expression: $ => prec.left(PREC.PIPE, seq(
      field("left", $._expression),
      "|>",
      field("right", $._expression),
    )),

    // Binary operators
    binary_expression: $ => choice(
      // || (left)
      prec.left(PREC.OR, seq(
        field("left", $._expression),
        field("operator", "||"),
        field("right", $._expression),
      )),
      // && (left)
      prec.left(PREC.AND, seq(
        field("left", $._expression),
        field("operator", "&&"),
        field("right", $._expression),
      )),
      // == != (left)
      prec.left(PREC.EQUALITY, seq(
        field("left", $._expression),
        field("operator", choice("==", "!=")),
        field("right", $._expression),
      )),
      // < > <= >= (left)
      prec.left(PREC.COMPARISON, seq(
        field("left", $._expression),
        field("operator", choice("<", ">", "<=", ">=")),
        field("right", $._expression),
      )),
      // + - (left)
      prec.left(PREC.ADDITION, seq(
        field("left", $._expression),
        field("operator", choice("+", "-")),
        field("right", $._expression),
      )),
      // * / (left)
      prec.left(PREC.MULTIPLY, seq(
        field("left", $._expression),
        field("operator", choice("*", "/")),
        field("right", $._expression),
      )),
    ),

    // Unary operators
    unary_expression: $ => prec(PREC.UNARY, choice(
      seq("-", $._expression),
      seq("not", $._expression),
    )),

    // Function application: f(args)
    application: $ => prec.left(PREC.APPLICATION, seq(
      field("function", $._expression),
      "(",
      optional(seq(
        field("argument", $._expression),
        repeat(seq(",", field("argument", $._expression))),
        optional(","),
      )),
      ")",
    )),

    // Dot access: expr.field
    dot_expression: $ => prec.left(PREC.DOT, seq(
      field("object", $._expression),
      ".",
      field("field", $.identifier),
    )),

    // Lambda: fn(params) -> body end
    lambda: $ => seq(
      "fn",
      $.parameter_list,
      "->",
      optional($._expression),
      "end",
    ),

    // Case expression
    case_expression: $ => seq(
      "case",
      field("scrutinee", $._expression),
      "do",
      repeat($.case_branch),
      "end",
    ),

    case_branch: $ => seq(
      field("pattern", $._pattern),
      "->",
      field("body", $._expression),
    ),

    // With expression (multi-scrutinee case)
    with_expression: $ => seq(
      "with",
      $._expression,
      repeat(seq(",", $._expression)),
      "do",
      repeat($.case_branch),
      "end",
    ),

    // Let expression
    let_expression: $ => prec.right(seq(
      "let",
      field("name", $.identifier),
      "=",
      field("value", $._expression),
      optional(field("body", $._expression)),
    )),

    // If expression
    if_expression: $ => seq(
      "if",
      field("condition", $._expression),
      "do",
      field("then", $._expression),
      "else",
      field("else", $._expression),
      "end",
    ),

    // ========================================================================
    // Patterns
    // ========================================================================

    _pattern: $ => choice(
      $.wildcard_pattern,
      $.variable_pattern,
      $.constructor_pattern,
      $.literal_pattern,
      $.record_pattern,
    ),

    wildcard_pattern: $ => "_",

    variable_pattern: $ => $.identifier,

    constructor_pattern: $ => prec(1, seq(
      field("name", choice($.identifier, $.type_identifier)),
      optional(seq(
        "(",
        optional(seq(
          $._pattern,
          repeat(seq(",", $._pattern)),
        )),
        ")",
      )),
    )),

    literal_pattern: $ => choice(
      $.integer,
      $.float,
      $.string,
      $.atom,
      "true",
      "false",
      seq("-", choice($.integer, $.float)),
    ),

    record_pattern: $ => seq(
      "%",
      $.type_identifier,
      "{",
      optional(seq(
        $.field_pattern,
        repeat(seq(",", $.field_pattern)),
      )),
      "}",
    ),

    field_pattern: $ => seq(
      field("name", $.identifier),
      ":",
      field("pattern", $._pattern),
    ),

    // ========================================================================
    // Terminals
    // ========================================================================

    variable: $ => $.identifier,

    type_variable: $ => $.type_identifier,

    type_universe: $ => "Type",

    hole: $ => "_",

    _literal: $ => choice(
      $.integer,
      $.float,
      $.string,
      $.atom,
      $.boolean,
    ),

    boolean: $ => choice("true", "false"),

    integer: $ => /[0-9]+/,

    float: $ => /[0-9]+\.[0-9]+/,

    string: $ => seq(
      '"',
      repeat(choice(
        $.escape_sequence,
        /[^"\\]+/,
      )),
      '"',
    ),

    escape_sequence: $ => token.immediate(seq(
      "\\",
      choice("n", "t", "\\", '"', "r", "0"),
    )),

    atom: $ => seq(":", $.identifier),

    // Identifiers: lowercase start
    identifier: $ => /[a-z_][a-zA-Z0-9_]*/,

    // Type identifiers: uppercase start
    type_identifier: $ => /[A-Z][a-zA-Z0-9_]*/,

    // Comments
    comment: $ => token(seq("#", /.*/)),
  },
});
