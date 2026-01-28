/* --------------------------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation. All rights reserved.
 * Licensed under the MIT License. See License.txt in the project root for license information.
 * ------------------------------------------------------------------------------------------ */

import * as path from 'path';
import { workspace, ExtensionContext } from 'vscode';

import {
	LanguageClient,
	LanguageClientOptions,
	ServerOptions,
	TransportKind,
} from 'vscode-languageclient/node';

let client: LanguageClient;

export function activate(context: ExtensionContext) {
	// The server is implemented in node
	const serverModule = context.asAbsolutePath(
		path.join('server', 'out', 'server.js')
	);

	// If the extension is launched in debug mode then the debug server options are used
	// Otherwise the run options are used
	const serverOptions: ServerOptions = {
		run: { module: serverModule, transport: TransportKind.ipc },
		debug: {
			module: serverModule,
			transport: TransportKind.ipc,
		}
	};

	// Options to control the language client
	const clientOptions: LanguageClientOptions = {
		// Register the server for bjy files
		documentSelector: [{ scheme: 'file', language: 'bjy' }],
		synchronize: {
			// Notify the server about file changes to '.clientrc files contained in the workspace
			fileEvents: workspace.createFileSystemWatcher('**/.clientrc')
		},
		middleware: {
			didChange: (change, next) => {
				const res = next(change);

				// TODO: should specify the type of c to make this more robust
				const norm = change.contentChanges.map((c) => {
					if (c.range && c.range.start && c.range.end) {
						return {
							range: {
								start: { line: Number(c.range.start.line), character: Number(c.range.start.character) },
								end:   { line: Number(c.range.end.line),   character: Number(c.range.end.character) },
							},
							text: String(c.text ?? ''),
						};
					}
					console.log("Ignoring full document change");
					return null;
				});

				try {
					client?.sendNotification('bluejay/rangeChanges', {
						uri: change.document?.uri?.toString() || '',
						contentChanges: norm,
					});
				} catch (error) {
					console.error('Failed to send bluejay/rangeChanges notification:', error);
				}

				return res;
			}
		}
	};

	// Create the language client and start the client.
	client = new LanguageClient(
		'languageServerExample',
		'Language Server Example',
		serverOptions,
		clientOptions
	);

	// Start the client. This will also launch the server
	client.start();
}

export function deactivate(): Thenable<void> | undefined {
	if (!client) {
		return undefined;
	}
	return client.stop();
}
