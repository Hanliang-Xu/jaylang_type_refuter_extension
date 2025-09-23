import {
	createConnection,
	TextDocuments,
	ProposedFeatures,
	TextDocumentSyncKind,
	InitializeResult
} from 'vscode-languageserver/node';

import {
	TextDocument
} from 'vscode-languageserver-textdocument';

import {
	execFile
} from 'child_process';

import {
	fileURLToPath
} from 'url';

// Create a connection for the server, using Node's IPC as a transport.
// Also include all preview / proposed LSP features.
const connection = createConnection(ProposedFeatures.all);

// Create a simple text document manager.
const documents = new TextDocuments(TextDocument);

connection.onInitialize((params): InitializeResult => {
	return {
		capabilities: {
			textDocumentSync: {
				openClose: true,
				change: TextDocumentSyncKind.None,
				save: { includeText: false }
			}
		}
	};
});

let workspaceRoot: string | undefined;
connection.onInitialized(async () => {
	const folders = await connection.workspace.getWorkspaceFolders();
	workspaceRoot = folders?.[0]?.uri ? fileURLToPath(folders[0].uri) : undefined;
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

// Run on every save
documents.onDidSave(e => {
	runCeval(e.document.uri).catch(err => {
		connection.console.error(String(err));
	});
});

// Make the text document manager listen on the connection
// for open, change and close text document events
documents.listen(connection);

// Listen on the connection
connection.listen();
