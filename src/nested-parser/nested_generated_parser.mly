%{
open Lexing;;

open Ast;;
open Ast_uid;;
open Nested_ast;;

module List = BatList;;
%}

%token <string> IDENTIFIER
%token OPEN_BRACE
%token CLOSE_BRACE
%token OPEN_PAREN
%token CLOSE_PAREN
%token COMMA
%token ARROW
%token QUESTION_MARK
%token TILDE
%token COLON
%token EQUALS
%token KEYWORD_FUN
%token KEYWORD_LET
%token KEYWORD_IN
%token DOUBLE_SEMICOLON
%token EOF

%start <Nested_ast.expr> prog
%start <Nested_ast.expr option> delim_expr

%%

prog:
  | expr EOF
      { $1 }
  ;

delim_expr:
  | EOF
      { None }
  | expr DOUBLE_SEMICOLON
      { Some($1) }
  | expr EOF
      { Some($1) }
  ;

expr:
  | let_body_expr
      { $1 }
  | KEYWORD_LET variable EQUALS expr KEYWORD_IN expr
      { Let_expr($2,$4,$6) }
  ;

let_body_expr:
  | application_expr
      { $1 }
  | let_body_expr TILDE pattern QUESTION_MARK function_value
                                        COLON function_value
      { Conditional_expr($1,$3,$5,$7) }
  ;
  
application_expr:
  | application_expr primary_expr
      { Appl_expr($1,$2) }
  | primary_expr
      { $1 }
  ;

primary_expr:
  | OPEN_BRACE separated_nonempty_trailing_list(COMMA, record_element) CLOSE_BRACE
      { Record_expr(Ident_map.of_enum @@ List.enum $2) }
  | OPEN_BRACE CLOSE_BRACE
      { Record_expr(Ident_map.empty) }
  | function_value
      { Function_expr($1) }
  | variable
      { Var_expr($1) }
  | OPEN_PAREN expr CLOSE_PAREN
      { $2 }
  ;

record_element:
  | identifier EQUALS expr
      { ($1,$3) }
  ;
  
pattern:
  | OPEN_BRACE separated_nonempty_trailing_list(COMMA, record_pattern_element) CLOSE_BRACE
      { Record_pattern(Ident_map.of_enum @@ List.enum $2) }
  | OPEN_BRACE CLOSE_BRACE
      { Record_pattern(Ident_map.empty) }
  ;
  
record_pattern_element:
  | identifier EQUALS pattern
      { ($1,$3) }
  ;
  
function_value:
  | KEYWORD_FUN variable ARROW primary_expr
      { Function($2,$4) } 
  ;

variable:
  | identifier
      { Var($1,None) }
  ;

identifier:
  | IDENTIFIER
      { Ident $1 }
  ;

separated_nonempty_trailing_list(separator, rule):
  | nonempty_list(terminated(rule, separator))
      { $1 }
  | separated_nonempty_list(separator,rule)
      { $1 }
  ;
