import {
  createConnection,
  ProposedFeatures,
  TextDocuments,
  TextDocumentSyncKind,
  InitializeResult,
  Diagnostic,
  DiagnosticSeverity,
  Range,
  Position,
} from 'vscode-languageserver/node';
import { TextDocument } from 'vscode-languageserver-textdocument';

import { execFile } from 'child_process';
import { fileURLToPath } from 'url';
import { runJsonParserFromString, StatementInfo } from './parser';

// ----- LSP wiring -----
const connection = createConnection(ProposedFeatures.all);
const documents = new TextDocuments(TextDocument);

// ----- Capabilities -----
connection.onInitialize((_params): InitializeResult => {
  connection.console.info('bluejay-lsp init: change=Incremental');
  return {
    capabilities: {
      textDocumentSync: {
        openClose: true,
        change: TextDocumentSyncKind.Incremental,
        save: { includeText: false },
      },
    },
  };
});

// ----- Workspace root -----
let workspaceRoot: string | undefined;
connection.onInitialized(async () => {
  const folders = await connection.workspace.getWorkspaceFolders();
  workspaceRoot = folders?.[0]?.uri ? fileURLToPath(folders[0].uri) : process.cwd();
  console.log('Workspace root:', workspaceRoot);
});

function runCeval(uri: string): Promise<void> {
  const fsPath = fileURLToPath(uri);
  const cevalPath = './ceval.exe';

  return new Promise((resolve) => {
    execFile(cevalPath, [fsPath], { cwd: workspaceRoot }, (err, stdout, stderr) => {
      const msg = (stdout || '') + (stderr || '');
      if (err) {
        connection.window.showErrorMessage(`ceval failed: ${msg || err.message}`);
      } else {
        connection.window.showInformationMessage(`ceval output: ${msg}`);
      }
      resolve();
    });
  });
}


// ----- Diagnostics -----
function createDiagnostics(statement: StatementInfo): Diagnostic {
  const startPos = Position.create(statement.start.line - 1, statement.start.col);
  const endPos = Position.create(statement.end.line - 1, statement.end.col);

  return {
    range: Range.create(startPos, endPos),
    severity: DiagnosticSeverity.Information,
    message: `Statement: ${statement.kind} (${statement.ids.join(', ')})`,
    source: 'bluejay-lsp',
  };
}

// ----- Receive exact edit ranges from client middleware -----
interface ChangeWithRange { range?: Range; rangeLength?: number; text: string }

interface ProcessedChange {
  type: 'range' | 'full';
  uri: string;
  version: number;
  text: string;
  textLength: number;
  originalRange?: { start: Position; end: Position };
  newRange?: { start: Position; end: Position };
}

interface MatchedChange {
  change: ProcessedChange;
  affectedStatementIndex: number;
  statement: StatementInfo;
}

function processRangeChange(change: ChangeWithRange, uri: string, version: number): ProcessedChange {
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

function matchChangeToStatements(change: ProcessedChange, statements: StatementInfo[]): MatchedChange | null {
  // Handle empty statements array
  if (statements.length === 0) {
    connection.console.info('No statements found, cannot match change');
    return null;
  }

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
  
  connection.console.info(`matched change to statement ${affectedStatementIndex}`);
  
  // Ensure the index is within bounds
  if (affectedStatementIndex < 0 || affectedStatementIndex >= statements.length) {
    connection.console.info(`Invalid statement index ${affectedStatementIndex}, using first statement`);
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

function findStatementAtPosition(statements: StatementInfo[], position: Position, text_length: number): number {
  // Find the first statement that starts at or after the given position
  for (let i = 0; i < statements.length; i++) {
    const stmt = statements[i];

    connection.console.info(
      `Checking stmt[${i}] end=(${stmt.end.line}, ${stmt.end.col}) vs position=(${position.line}, ${position.character})`
    );

    if ((stmt.end.line - 1) > position.line || 
        ((stmt.end.line - 1) === position.line && stmt.end.col >= (position.character + text_length))) {
      connection.console.info(`found statement at index ${i}`);
      connection.console.info(`statement: ${stmt.kind} (${stmt.ids.join(', ')})`);
      return i;
    }
  }
  
  // If no statement found, return the last one
  return statements.length - 1;
}

connection.onNotification('bluejay/rangeChanges', async (payload: {
  uri: string;
  version: number;
  contentChanges: ChangeWithRange[];
}) => {
  // Handle the case where uri might be an object
  const uri = typeof payload.uri === 'string' ? payload.uri : String(payload.uri);
  connection.console.info(`Received notification for URI: ${uri}`);
  
  const change = processRangeChange(payload.contentChanges[0], uri, payload.version);
 
  // Log the changes
  if (change.type === 'range') {
    connection.console.info(
      `v${change.version} ${change.originalRange!.start.line}:${change.originalRange!.start.character}-${change.originalRange!.end.line}:${change.originalRange!.end.character} ` +
      `→ post ${change.newRange!.end.line}:${change.newRange!.end.character} len=${change.textLength}`
    );
  } else {
    connection.console.info(`v${change.version} full replace len=${change.textLength}`);
  };

  // Parse the current document content
  try {
    const document = documents.get(uri);
    connection.console.info(`Looking for document: ${uri}`);
    connection.console.info(`Document found: ${!!document}`);
    
    if (document) {
      const content = document.getText();
      const statements = await runJsonParserFromString(uri, content);
      
      connection.console.info(`parsed ${statements.length} statements`);
      connection.console.info(`All statements: ${JSON.stringify(statements, null, 2)}`);

      // Match changes to statements
      const matchedChange = matchChangeToStatements(change, statements);
      
      if (!matchedChange) {
        connection.console.info('No statements to create diagnostics for');
        connection.sendDiagnostics({ uri, diagnostics: [] });
        return;
      }
      
      // Create diagnostics based on the statements
      connection.console.info(`Creating diagnostic for statement: ${JSON.stringify(matchedChange.statement, null, 2)}`);
      
      if (!matchedChange.statement.start) {
        connection.console.error(`Statement missing start property: ${JSON.stringify(matchedChange.statement)}`);
        return;
      }
      
      const diagnostics = createDiagnostics(matchedChange.statement);
      connection.sendDiagnostics({ uri, diagnostics: [diagnostics] });
    } else {
      connection.console.info(`Document not found in LSP cache: ${uri}`);
      // Try to get the document from the change event instead
      const allDocuments = documents.all();
      connection.console.info(`Available documents: ${allDocuments.map(d => d.uri).join(', ')}`);
    }
  } catch (err) {
    connection.console.error(`Parser error: ${err}`);
    connection.sendDiagnostics({ uri, diagnostics: [] });
  }
});

// ----- Document handlers -----
documents.onDidOpen((event) => {
  connection.console.info(`Document opened: ${event.document.uri}`);
});

documents.onDidChangeContent((event) => {
  connection.console.info(`Document changed: ${event.document.uri}`);
});

// ----- Start listening -----
documents.listen(connection);
connection.listen();
