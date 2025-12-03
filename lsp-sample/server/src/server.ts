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

import { execFile, ChildProcess } from 'child_process';
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

// ----- State Management for Parallel Check Execution -----
interface StatementValidity {
  statementIndex: number;
  status: 'pending' | 'running' | 'valid' | 'invalid' | 'error' | 'timeout' | 'pruned';
  lastUpdated: number; // timestamp in milliseconds
}

// Per-document state: Map<uri, Map<statementIndex, StatementValidity>>
const documentState = new Map<string, Map<number, StatementValidity>>();

// Track running processes: Map<uri, Map<statementIndex, ChildProcess>>
const runningProcesses = new Map<string, Map<number, ChildProcess>>();

// Track previous document content to detect change positions: Map<uri, string>
const previousDocumentContent = new Map<string, string>();

// ----- Helper: Cancel running processes for a document -----
// If minStatementIndex is provided, only cancels processes for statements >= minStatementIndex
// Otherwise, cancels all processes for the document
function cancelRunningProcesses(uri: string, minStatementIndex: number): void {
  const processes = runningProcesses.get(uri);
  if (!processes) {
    return; // No processes running for this document
  }

  // Cancel only processes for statements >= minStatementIndex
  let cancelledCount = 0;
  processes.forEach((process, statementIndex) => {
    if (statementIndex >= minStatementIndex) {
      try {
        process.kill('SIGTERM');
        connection.console.info(`Killed process for statement ${statementIndex} (>= ${minStatementIndex})`);
        cancelledCount++;
      } catch (err) {
        connection.console.error(`Error killing process for statement ${statementIndex}: ${err}`);
      }
    }
  });

  // Remove cancelled processes from the map
  processes.forEach((process, statementIndex) => {
    if (statementIndex >= minStatementIndex) {
      processes.delete(statementIndex);
    }
  });

  connection.console.info(`Cancelled ${cancelledCount} processes for statements >= ${minStatementIndex} in ${uri}`);
  
  // If no processes remain, clean up the map
  if (processes.size === 0) {
    runningProcesses.delete(uri);
  }
}

// ----- Helper: Generate diagnostics from state map -----
function generateDiagnostics(
  uri: string,
  statements: StatementInfo[],
  state: Map<number, StatementValidity>
): Diagnostic[] {
  const diagnostics: Diagnostic[] = [];

  for (const statement of statements) {
    const validity = state.get(statement.index);
    
    if (!validity) {
      // No validity info yet, skip
      continue;
    }

    const startPos = Position.create(statement.start.line - 1, statement.start.col);
    const endPos = Position.create(statement.end.line - 1, statement.end.col);

    // Only show diagnostics for completed checks (skip running to reduce noise)
    // But show pending status as it indicates "no definitive answer yet"
    if (validity.status === 'running') {
      // Skip running - too noisy
      continue;
    }

    // Map status to diagnostic severity
    let severity: DiagnosticSeverity;
    let message: string;

    switch (validity.status) {
      case 'valid':
        severity = DiagnosticSeverity.Information;
        message = `Statement ${statement.index} is valid`;
        break;
      case 'invalid':
        severity = DiagnosticSeverity.Error;
        message = `Statement ${statement.index} is invalid`;
        break;
      case 'error':
        severity = DiagnosticSeverity.Error;
        message = `Error checking statement ${statement.index}`;
        break;
      case 'timeout':
        severity = DiagnosticSeverity.Warning;
        message = `Check timeout for statement ${statement.index}`;
        break;
      case 'pruned':
        severity = DiagnosticSeverity.Warning;
        message = `Statement ${statement.index} check pruned`;
        break;
      case 'pending':
        continue;
      default:
        severity = DiagnosticSeverity.Warning;
        message = `Unknown status for statement ${statement.index}`;
    }

    diagnostics.push({
      range: Range.create(startPos, endPos),
      severity,
      message,
      source: 'bluejay-lsp',
    });
  }

  return diagnostics;
}

// ----- Helper: Promise wrapper for execFile -----
function execFilePromise(
  command: string,
  args: string[],
  options: { cwd?: string }
): { 
  promise: Promise<{ stdout: string; stderr: string; exitCode: number | null }>;
  process: ChildProcess;
} {
  let processHandle: ChildProcess;
  
  const promise = new Promise<{ stdout: string; stderr: string; exitCode: number | null }>((resolve, reject) => {
    processHandle = execFile(
      command,
      args,
      options,
      (err, stdout, stderr) => {
        if (err) {
          resolve({
            stdout: stdout || '',
            stderr: stderr || '',
            exitCode: (err as any).code ?? null,
          });
        } else {
          resolve({
            stdout: stdout || '',
            stderr: stderr || '',
            exitCode: 0,
          });
        }
      }
    );
  });
  
  return { promise, process: processHandle! };
}

// ----- Helper: Parse ceval.exe output and determine status -----
// Returns the raw status string from output for two-phase checking
function parseCevalOutputRaw(stdout: string, stderr: string, exitCode: number | null): {
  statusString: string;
} {
  const output = (stdout || '') + (stderr || '');
  const outputUpper = output.toUpperCase();

  // Check for error conditions first
  if (exitCode !== null && exitCode !== 0) {
    return {
      statusString: 'ERROR',
    };
  }

  // Parse status from output (ceval uses to_loud_string which uppercases and replaces spaces with underscores)
  if (outputUpper.includes('FOUND_ABORT')) {
    return {
      statusString: 'FOUND_ABORT',
    };
  }

  if (outputUpper.includes('TYPE_MISMATCH')) {
    return {
      statusString: 'TYPE_MISMATCH',
    };
  }

  if (outputUpper.includes('UNBOUND_VARIABLE')) {
    return {
      statusString: 'UNBOUND_VARIABLE',
    };
  }

  if (outputUpper.includes('TIMEOUT')) {
    return {
      statusString: 'TIMEOUT',
    };
  }

  if (outputUpper.includes('EXHAUSTED_PRUNED_TREE')) {
    return {
      statusString: 'EXHAUSTED_PRUNED_TREE',
    };
  }

  if (outputUpper.includes('EXHAUSTED')) {
    return {
      statusString: 'EXHAUSTED',
    };
  }

  if (outputUpper.includes('UNKNOWN_DUE_TO_SOLVER_TIMEOUT')) {
    return {
      statusString: 'UNKNOWN_DUE_TO_SOLVER_TIMEOUT',
    };
  }

  // Default: if we got here and exit code was 0, assume unfinished/incomplete
  if (exitCode === 0) {
    return {
      statusString: 'UNFINISHED',
    };
  }

  // Unknown output format
  return {
    statusString: 'ERROR',
  };
}

// Convert raw status string to StatementValidity status after two-phase check
function convertStatusToValidity(statusString: string): {
  status: StatementValidity['status'];
} {
  switch (statusString) {
    case 'EXHAUSTED':
      return { status: 'valid' };
    case 'EXHAUSTED_PRUNED_TREE':
      return { status: 'pruned' };
    case 'UNFINISHED':
      return { status: 'pending' };
    case 'FOUND_ABORT':
    case 'TYPE_MISMATCH':
    case 'UNBOUND_VARIABLE':
      return { status: 'invalid' };
    case 'TIMEOUT':
      return { status: 'timeout' };
    case 'UNKNOWN_DUE_TO_SOLVER_TIMEOUT':
    case 'ERROR':
    default:
      return { status: 'error' };
  }
}

// ----- Main function: Run parallel checks for all statements -----
// If minStatementIndex is provided, only cancels and starts checks for statements >= minStatementIndex
// Preserves state and running processes for statements < minStatementIndex
async function runParallelChecks(uri: string, statements: StatementInfo[], fsPath: string, minStatementIndex?: number): Promise<void> {
  // 1. Get or initialize state map
  let state = documentState.get(uri);
  if (!state) {
    state = new Map<number, StatementValidity>();
  }

  // 2. Get or initialize processes map
  let processes = runningProcesses.get(uri);
  if (!processes) {
    processes = new Map<number, ChildProcess>();
  }

  if (statements.length === 0) {
    connection.console.info(`No statements found for ${uri}`);
    return;
  }

  // 3. Determine which statements to check
  const statementsToCheck = minStatementIndex !== undefined
    ? statements.filter(stmt => stmt.index >= minStatementIndex)
    : statements;

  if (statementsToCheck.length === 0) {
    connection.console.info(`No statements to check (minStatementIndex=${minStatementIndex})`);
    return;
  }

  // 4. Cancel existing processes for statements we're about to recheck
  if (minStatementIndex !== undefined) {
    cancelRunningProcesses(uri, minStatementIndex);
    connection.console.info(`Starting checks for ${statementsToCheck.length} statements (>= ${minStatementIndex})`);
  } else {
    cancelRunningProcesses(uri, 0);
    connection.console.info(`Starting parallel checks for ${statements.length} statements`);
  }

  // 5. Initialize state for statements we're checking (preserve state for earlier statements)
  for (const stmt of statementsToCheck) {
    state.set(stmt.index, {
      statementIndex: stmt.index,
      status: 'pending',
      lastUpdated: Date.now(),
    });
  }

  // 6. Send initial diagnostics (preserving diagnostics for statements we're not rechecking)
  const initialDiagnostics = generateDiagnostics(uri, statements, state);
  connection.sendDiagnostics({ uri, diagnostics: initialDiagnostics });

  // 7. Spawn ceval.exe process for each statement to check with --check-index
  const cevalPath = './ceval.exe';

  // Create promises for all checks - they start executing immediately
  const checkPromises = statementsToCheck.map(async (stmt) => {
    const statementIndex = stmt.index;
    
    // Update status to 'running'
    state.set(statementIndex, {
      statementIndex,
      status: 'running',
      lastUpdated: Date.now(),
    });

    // Send updated diagnostics
    const runningDiagnostics = generateDiagnostics(uri, statements, state);
    connection.sendDiagnostics({ uri, diagnostics: runningDiagnostics });

    // Two-phase checking: first with -s flag, then without if needed
    try {
      // Phase 1: Run with -s flag (incomplete but sound checking)
      connection.console.info(`Check ${statementIndex} phase 1: running with -s flag`);
      const { promise: promisePhase1, process: processPhase1 } = execFilePromise(
        cevalPath,
        [fsPath, '--check-index', statementIndex.toString(), '-s'],
        { cwd: workspaceRoot }
      );

      // Store process reference immediately (needed for cancellation)
      processes.set(statementIndex, processPhase1);

      const resultPhase1 = await promisePhase1;
      const parsedPhase1 = parseCevalOutputRaw(resultPhase1.stdout, resultPhase1.stderr, resultPhase1.exitCode);

      connection.console.info(`Check ${statementIndex} phase 1 result: ${parsedPhase1.statusString}`);

      let finalStatus: StatementValidity['status'];

      // If EXHAUSTED in phase 1, statement is safe (valid)
      if (parsedPhase1.statusString === 'EXHAUSTED') {
        finalStatus = 'valid';
        connection.console.info(`Check ${statementIndex} completed: valid (EXHAUSTED in phase 1)`);
      } else {
        // Phase 2: Run without -s flag for complete checking
        connection.console.info(`Check ${statementIndex} phase 2: running without -s flag`);
        const { promise: promisePhase2, process: processPhase2 } = execFilePromise(
          cevalPath,
          [fsPath, '--check-index', statementIndex.toString()],
          { cwd: workspaceRoot }
        );

        // Update process reference for cancellation
        processes.set(statementIndex, processPhase2);

        const resultPhase2 = await promisePhase2;
        const parsedPhase2 = parseCevalOutputRaw(resultPhase2.stdout, resultPhase2.stderr, resultPhase2.exitCode);

        connection.console.info(`Check ${statementIndex} phase 2 result: ${parsedPhase2.statusString}`);

        // Convert phase 2 result to validity status
        const converted = convertStatusToValidity(parsedPhase2.statusString);
        finalStatus = converted.status;

        connection.console.info(`Check ${statementIndex} completed: ${finalStatus}`);
      }

      // Update state with final result
      state.set(statementIndex, {
        statementIndex,
        status: finalStatus,
        lastUpdated: Date.now(),
      });

      // Remove from running processes
      processes.delete(statementIndex);

      // Send incremental diagnostics update (as soon as this check completes)
      // Use all statements (not just statementsToCheck) to preserve diagnostics for earlier statements
      const updatedDiagnostics = generateDiagnostics(uri, statements, state);
      connection.sendDiagnostics({ uri, diagnostics: updatedDiagnostics });
    } catch (error) {
      // Handle unexpected errors
      state.set(statementIndex, {
        statementIndex,
        status: 'error',
        lastUpdated: Date.now(),
      });

      processes.delete(statementIndex);

      // Use all statements (not just statementsToCheck) to preserve diagnostics for earlier statements
      const updatedDiagnostics = generateDiagnostics(uri, statements, state);
      connection.sendDiagnostics({ uri, diagnostics: updatedDiagnostics });

      connection.console.error(`Check ${statementIndex} failed: ${error}`);
    }
  });

  // Store state and processes maps immediately (before promises complete)
  documentState.set(uri, state);
  runningProcesses.set(uri, processes);

  // Wait for all checks to complete (but diagnostics are sent incrementally above)
  // This ensures we can track when all are done for cleanup/logging
  await Promise.allSettled(checkPromises);
  
  connection.console.info(`All checks completed for ${uri}${minStatementIndex !== undefined ? ` (for statements >= ${minStatementIndex})` : ''}`);
}

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
  const uri = event.document.uri;
  connection.console.info(`Document opened: ${uri}`);
  // Initialize previous content for change detection
  previousDocumentContent.set(uri, event.document.getText());
});

documents.onDidClose((event) => {
  const uri = event.document.uri;
  connection.console.info(`Document closed: ${uri}`);
  // Cancel any running processes and clean up state
  cancelRunningProcesses(uri, 0);
  documentState.delete(uri);
  previousDocumentContent.delete(uri);
  // Clear diagnostics
  connection.sendDiagnostics({ uri, diagnostics: [] });
});

// Helper: Find the first position where two strings differ
function findFirstDifference(oldText: string, newText: string): Position | null {
  const minLength = Math.min(oldText.length, newText.length);
  
  // Find first character difference
  for (let i = 0; i < minLength; i++) {
    if (oldText[i] !== newText[i]) {
      // Convert character offset to line/character position
      const beforeDiff = oldText.substring(0, i);
      const line = (beforeDiff.match(/\n/g) || []).length;
      const lastNewline = beforeDiff.lastIndexOf('\n');
      const character = lastNewline === -1 ? i : i - lastNewline - 1;
      return Position.create(line, character);
    }
  }
  
  // If one string is longer, the difference starts at the end of the shorter one
  if (oldText.length !== newText.length) {
    const shorter = oldText.length < newText.length ? oldText : newText;
    const line = (shorter.match(/\n/g) || []).length;
    const lastNewline = shorter.lastIndexOf('\n');
    const character = lastNewline === -1 ? shorter.length : shorter.length - lastNewline - 1;
    return Position.create(line, character);
  }
  
  return null; // Strings are identical
}

documents.onDidChangeContent(async (event) => {
  const uri = event.document.uri;
  connection.console.info(`Document changed: ${uri}`);
  
  // Get current document content
  const currentContent = event.document.getText();
  
  // Parse statements from the document
  const statements = await runJsonParserFromString(uri, currentContent);
  
  if (statements.length === 0) {
    connection.console.info(`No statements found in ${uri}`);
    // Clear diagnostics if no statements
    connection.sendDiagnostics({ uri, diagnostics: [] });
    previousDocumentContent.set(uri, currentContent);
    return;
  }
  
  // Determine which statement was edited by comparing with previous content
  let minStatementIndex: number | undefined = undefined;
  
  const previousContent = previousDocumentContent.get(uri);
  if (previousContent !== undefined && previousContent !== currentContent) {
    // Find where the change occurred
    const changePosition = findFirstDifference(previousContent, currentContent);
    
    if (changePosition) {
      // Estimate text length of the change (rough approximation)
      const textLength = Math.abs(currentContent.length - previousContent.length);
      minStatementIndex = findStatementAtPosition(statements, changePosition, textLength);
      connection.console.info(`Edit detected at position (${changePosition.line}, ${changePosition.character}), affecting statement ${minStatementIndex}`);
    } else {
      // Couldn't determine change position, recheck all
      connection.console.info(`Could not determine change position, rechecking all statements`);
      minStatementIndex = undefined;
    }
  } else {
    // First time seeing this document or no previous content: recheck all statements
    connection.console.info(`First change or no previous content, rechecking all statements`);
    minStatementIndex = undefined;
  }
  
  // Store current content for next comparison
  previousDocumentContent.set(uri, currentContent);
  
  // Run parallel checks, preserving processes for statements before the edited one
  const fsPath = fileURLToPath(uri);
  runParallelChecks(uri, statements, fsPath, minStatementIndex);
});

// ----- Start listening -----
documents.listen(connection);
connection.listen();
