import {
  createConnection,
  ProposedFeatures,
  TextDocuments,
  TextDocumentSyncKind,
  InitializeResult,
} from 'vscode-languageserver/node';
import { TextDocument } from 'vscode-languageserver-textdocument';

import { fileURLToPath } from 'url';
import { runJsonParserFromString } from './parser';
import { createDiagnosticFromCheckResult } from './diagnostics';
import { ChangeWithRange, processRangeChange, matchChangeToStatements } from './change_analyzer';
import { checkAllStatements } from './checker';

const connection = createConnection(ProposedFeatures.all);
const documents = new TextDocuments(TextDocument);

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

let workspaceRoot: string;
connection.onInitialized(async () => {
  const folders = await connection.workspace.getWorkspaceFolders();
  workspaceRoot = folders?.[0]?.uri ? fileURLToPath(folders[0].uri) : process.cwd();
});

connection.onNotification('bluejay/rangeChanges', async (payload: {
  uri: string;
  contentChanges: ChangeWithRange[];
}) => {
  const uri = payload.uri;
  const change = processRangeChange(payload.contentChanges[0], uri);

  try {    
    const document = documents.get(uri);
    
    if (document) {
      const content = document.getText();
      const statements = await runJsonParserFromString(uri, content);
      const check_results = await checkAllStatements(statements, workspaceRoot, content);

      const matchedChange = matchChangeToStatements(change, statements);

      if (!matchedChange || !matchedChange.statement) {
        connection.console.error(`Change-statement matching error`);
        return;
      }
      
      const diagnostics = check_results.map(result => {
        const statement = statements.find(s => s.index === result.statementIndex);

        const diagnostic = createDiagnosticFromCheckResult(statement!, result);

        if (matchedChange && statement!.index === matchedChange.affectedStatementIndex) {
          diagnostic.message = `[Edited] ${diagnostic.message}`;
        }

        // Maybe this statement! is unsafe? Needs to check if can do this in a safer way
        return diagnostic;
      });

      connection.sendDiagnostics({ uri, diagnostics });
    }
  } catch (err) {
    connection.console.error(`Parser error: ${err}`);
    connection.sendDiagnostics({ uri, diagnostics: [] });
  }
});

documents.listen(connection);
connection.listen();
