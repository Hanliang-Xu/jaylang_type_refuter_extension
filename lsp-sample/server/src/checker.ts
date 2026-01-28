import { execFile } from 'child_process';
import { promisify } from 'util';
import { writeFile, unlink } from 'fs/promises';
import { tmpdir } from 'os';
import { join } from 'path';
import { StatementInfo } from './parser';

const execFileAsync = promisify(execFile);

export async function checkStatement(
    statementIndex: number,
    workspaceRoot: string,
    content: string,
): Promise<{ isValid: boolean; message: string }> {
    const cevalPath = './ceval.exe';

    const tempFile = join(tmpdir(), `bjy-${Date.now()}-${Math.random().toString(36)}.bjy`);

    try {
        await writeFile(tempFile, content, 'utf-8');

        const { stdout, stderr } = await execFileAsync(
            cevalPath,
            [tempFile, '--check-index', statementIndex.toString()],
            { cwd: workspaceRoot }
        );

        const output = (stdout || '') + (stderr || '');

        if (output.includes('EXHAUSTED')) {
            return { isValid: true, message: output };
        } else {
            return { isValid: false, message: output };
        }

    } catch (error) {
        return {
            isValid: false,
            message: `Execution error: ${error || 'Unknown error'}`
        };
    } finally {
        try {
            await unlink(tempFile);
        } catch (cleanupError) {
            console.log("error while cleaning up the temp file for checking" + cleanupError);
        }
    }
}

export async function checkAllStatements(
    statements: StatementInfo[],
    workspaceRoot: string,
    content: string,
): Promise<{ statementIndex: number; isValid: boolean; message: string }[]> {
    const results = [];

    // Do we actually need to pass the statements here? Might not?
    for (const statement of statements) {
        const result = await checkStatement(statement.index, workspaceRoot, content);
        results.push({ statementIndex: statement.index, ...result });
    }
    
    return results;
}