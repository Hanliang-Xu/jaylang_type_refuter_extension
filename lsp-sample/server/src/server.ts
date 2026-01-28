import {
  createConnection,
  ProposedFeatures,
  TextDocuments,
  TextDocumentSyncKind,
  InitializeResult,
} from 'vscode-languageserver/node';
import { TextDocument } from 'vscode-languageserver-textdocument';

// import { execFile } from 'child_process';
import { fileURLToPath } from 'url';
import { runJsonParserFromString } from './parser';
import { createDiagnostics } from './diagnostics';
import { ChangeWithRange, processRangeChange, matchChangeToStatements } from './change_analyzer'

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
});

// function runCeval(uri: string): Promise<void> {
//   const fsPath = fileURLToPath(uri);
//   const cevalPath = './ceval.exe';

//   return new Promise((resolve) => {
//     execFile(cevalPath, [fsPath], { cwd: workspaceRoot }, (err, stdout, stderr) => {
//       const msg = (stdout || '') + (stderr || '');
//       if (err) {
//         connection.window.showErrorMessage(`ceval failed: ${msg || err.message}`);
//       } else {
//         connection.window.showInformationMessage(`ceval output: ${msg}`);
//       }
//       resolve();
//     });
//   });
// }

connection.onNotification('bluejay/rangeChanges', async (payload: {
  uri: string;
  contentChanges: ChangeWithRange[];
}) => {
  // Handle the case where uri might be an object
  const uri = typeof payload.uri === 'string' ? payload.uri : String(payload.uri);
  
  const change = processRangeChange(payload.contentChanges[0], uri);

  // Parse the current document content
  try {
    const document = documents.get(uri);
    
    if (document) {
      const content = document.getText();
      const statements = await runJsonParserFromString(uri, content);
      
      const matchedChange = matchChangeToStatements(change, statements);
      
      if (!matchedChange || !matchedChange.statement) {
        connection.console.error(`Change-statement matching error`);
        return;
      }
      
      const diagnostics = createDiagnostics(matchedChange.statement);
      connection.sendDiagnostics({ uri, diagnostics: [diagnostics] });
    }
  } catch (err) {
    connection.console.error(`Parser error: ${err}`);
    connection.sendDiagnostics({ uri, diagnostics: [] });
  }
});

documents.listen(connection);
connection.listen();
