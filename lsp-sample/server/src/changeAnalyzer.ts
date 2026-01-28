import {
  Range,
  Position,
} from 'vscode-languageserver/node';

import { StatementInfo } from './parser';

// Types
export interface ChangeWithRange { range?: Range; rangeLength?: number; text: string }

export interface ProcessedChange {
  type: 'range' | 'full';
  uri: string;
  version: number;
  text: string;
  textLength: number;
  originalRange?: Range;
  newRange?: Range;
}

export interface MatchedChange {
  change: ProcessedChange;
  affectedStatementIndex: number;
  statement: StatementInfo;
}

export function processRangeChange(change: ChangeWithRange, uri: string, version: number): ProcessedChange {
  const baseChange = {
    uri,
    version,
    text: change.text,
    textLength: change.text.length
  };

  if (change.range) {
    // Range change: calculate new end position
    const { start, end } = change.range;
    const nl = (change.text.match(/\n/g)?.length ?? 0);
    const lastLineLen = change.text.length - (change.text.lastIndexOf('\n') + 1);
    const postEnd = nl === 0
      ? { line: start.line, character: start.character + lastLineLen }
      : { line: start.line + nl, character: lastLineLen };

    return {
      ...baseChange,
      type: 'range' as const,
      originalRange: { start, end },
      newRange: { start, end: postEnd }
    };
  } else {
    // Full change: no range information
    return {
      ...baseChange,
      type: 'full' as const
    };
  }
}

export function matchChangeToStatements(change: ProcessedChange, statements: StatementInfo[]): MatchedChange | null {
  if (change.type === 'full') {
    // Full changes affect all statements
    return {
      change,
      affectedStatementIndex: 0,
      statement: statements[0]
    };
  }

  const matchPosition = change.newRange!.start;

  // Find the statement that contains or is after this position
  const affectedStatementIndex = findStatementAtPosition(statements, matchPosition, change.textLength);
  
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

export function findStatementAtPosition(statements: StatementInfo[], position: Position, text_length: number): number {
  // Find the first statement that starts at or after the given position
  for (let i = 0; i < statements.length; i++) {
    const stmt = statements[i];

    if ((stmt.end.line - 1) > position.line || 
        ((stmt.end.line - 1) === position.line && stmt.end.col >= (position.character + text_length))) {
      return i;
    }
  }
  
  // If no statement found, return the last one
  return statements.length - 1;
}