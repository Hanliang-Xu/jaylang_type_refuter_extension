import { execFile } from 'child_process';
import { fileURLToPath } from 'url';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

export interface ParserPosition {
  line: number;
  col: number;
  offset: number;
}

export interface StatementInfo {
  index: number;
  kind: string;
  ids: string[];
  start: ParserPosition;
  end: ParserPosition;
}

export function runJsonParser(fileUri: string, workspaceRoot?: string): Promise<StatementInfo[]> {
  const fsPath = fileURLToPath(fileUri);
  const jsonParserPath = './json_parser.exe';

  return new Promise((resolve, reject) => {
    execFile(jsonParserPath, [fsPath], { cwd: workspaceRoot }, (err, stdout, stderr) => {
      if (err) {
        resolve([]);
        return;
      }
      try {
        const statements: StatementInfo[] = JSON.parse(stdout);
        resolve(statements);
      } catch (parseErr) {
        resolve([]);
      }
    });
  });
}

// Write current in-memory content to a temp file and reuse the file-based parser
export async function runJsonParserFromString(uri: string, content: string): Promise<StatementInfo[]> {
  const base = Buffer.from(uri).toString('base64').replace(/=+$/, '');
  const tmpDir = path.join(os.tmpdir(), 'bluejay-lsp');
  fs.mkdirSync(tmpDir, { recursive: true });
  const tmpPath = path.join(tmpDir, `${base}.tmp.bjy`);
  fs.writeFileSync(tmpPath, content, 'utf8');
  return runJsonParser(pathToFileUri(tmpPath));
}

function pathToFileUri(p: string): string {
  let rp = p.replace(/\\/g, '/');
  if (!rp.startsWith('/')) rp = '/' + rp;
  return `file://${rp}`;
}