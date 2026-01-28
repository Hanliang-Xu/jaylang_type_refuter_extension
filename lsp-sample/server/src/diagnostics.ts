import {
  Diagnostic,
  DiagnosticSeverity,
  Range,
  Position,
} from 'vscode-languageserver/node';
import { StatementInfo } from './parser';


export function createDiagnosticOnChangedStmt(statement: StatementInfo): Diagnostic {
    const startPos : Position = Position.create(statement.start.line - 1, statement.start.col);
    const endPos : Position = Position.create(statement.end.line - 1, statement.end.col);

    return {
        range: Range.create(startPos, endPos),
        severity: DiagnosticSeverity.Hint,
        message: `Statement: ${statement.kind} (${statement.ids.join(', ')})`,
        source: 'bluejay-lsp',
    };
}

export function createDiagnosticFromCheckResult(
    statement: StatementInfo,
    checkResult: { isValid: boolean; message: string }
): Diagnostic {
    const startPos = Position.create(statement.start.line - 1, statement.start.col);
    const endPos = Position.create(statement.end.line - 1, statement.end.col);

    return {
        range: Range.create(startPos, endPos),
        severity: checkResult.isValid ? DiagnosticSeverity.Information : DiagnosticSeverity.Error,
        message: checkResult.message,
        source: 'bluejay-lsp',
    };
}