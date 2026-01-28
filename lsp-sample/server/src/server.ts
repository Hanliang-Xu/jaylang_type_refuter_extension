import {
  createConnection,
  ProposedFeatures,
  TextDocuments,
  TextDocumentSyncKind,
  InitializeResult,
} from 'vscode-languageserver/node';
import { TextDocument } from 'vscode-languageserver-textdocument';

import { execFile } from 'child_process';
import { fileURLToPath } from 'url';
import { runJsonParserFromString } from './parser';
import { createDiagnostics } from './diagnostics';
import { ChangeWithRange, processRangeChange, matchChangeToStatements } from './changeAnalyzer'

// ----- LSP wiring -----
const connection = createConnection(ProposedFeatures.all);
const documents = new TextDocuments(TextDocument);

// ----- Capabilities -----
connection.onInitialize((_params): InitializeResult => {
  connection.console.info('bluejay-lsp init');
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
