import {
  Diagnostic,
  DiagnosticSeverity,
  Range,
  Position,
} from 'vscode-languageserver/node';
import { StatementInfo } from './parser';


// ----- Diagnostics -----
export function createDiagnostics(statement: StatementInfo): Diagnostic {
  const startPos = Position.create(statement.start.line - 1, statement.start.col);
  const endPos = Position.create(statement.end.line - 1, statement.end.col);

  return {
    range: Range.create(startPos, endPos),
    severity: DiagnosticSeverity.Information,
    message: `Statement: ${statement.kind} (${statement.ids.join(', ')})`,
    source: 'bluejay-lsp',
  };
}