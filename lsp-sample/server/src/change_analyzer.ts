import {
  Range,
  Position,
} from 'vscode-languageserver/node';

import { StatementInfo } from './parser';

// Types
export interface ChangeWithRange { range: Range; text: string }

export interface ProcessedChange {
  uri: string;
  text: string;
  originalRange: Range;
  newRange: Range;
}

export interface MatchedChange {
  change: ProcessedChange;
  affectedStatementIndex: number;
  statement: StatementInfo;
}

// Functions that use these types
export function processRangeChange(change: ChangeWithRange, uri: string): ProcessedChange {
  const { start, end } = change.range;
  const nl = (change.text.match(/\n/g)?.length ?? 0);
  const lastLineLen = change.text.length - (change.text.lastIndexOf('\n') + 1);
  const postEnd = nl === 0
    ? { line: start.line, character: start.character + lastLineLen }
    : { line: start.line + nl, character: lastLineLen };

  return {
    uri,
    text: change.text,
    originalRange: { start, end },
    newRange: { start, end: postEnd }
  };
}

export function matchChangeToStatements(change: ProcessedChange, statements: StatementInfo[]): MatchedChange | null {
  const affectedStatementIndex = findStatementAtPosition(statements, change.newRange);
  
  // Ensure the index is within bounds
  if (affectedStatementIndex < 0 || affectedStatementIndex >= statements.length) {
    return {
      change,
      affectedStatementIndex: 0,
      statement: statements[0]
    };
  }
  
  return {
    change,
    affectedStatementIndex,
    statement: statements[affectedStatementIndex]
  };
}

export function findStatementAtPosition(statements: StatementInfo[], newRange: Range): number {
  for (let i = 0; i < statements.length; i++) {
    const stmt_end : Position = statements[i].end;
    const change_end : Position = newRange.end;

    if ((stmt_end.line - 1) > change_end.line || 
        ((stmt_end.line - 1) === change_end.line && stmt_end.character >= change_end.character)) {
      return i;
    }
  }
  
  return statements.length - 1;
}