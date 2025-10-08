import * as path from 'path';
import * as fs from 'fs';
import * as os from 'os';
import { runJsonParser, StatementInfo } from '../parser';
import { expect } from '@jest/globals';

describe('runJsonParser', () => {
    let tempDir: string;
    let testFileUri: string;

    beforeAll(() => {
        // Create a shared temporary directory and test file
        tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'parser-test-'));
        const testFile = path.join(tempDir, 'test.bjy');
        const testContent = `let x = 1 let y = 2\nlet z = 3`;
        fs.writeFileSync(testFile, testContent, 'utf8');
        testFileUri = `file://${testFile}`;
    });

    afterAll(() => {
        // Clean up the temporary directory
        if (fs.existsSync(tempDir)) {
            fs.rmSync(tempDir, { recursive: true, force: true });
        }
    });

    test('should parse simple variable declarations', async () => {
        const statements = await runJsonParser(testFileUri);

        expect(statements).toHaveLength(3);
        expect(statements[0].ids).toEqual(['x']);
        expect(statements[1].ids).toEqual(['y']);
        expect(statements[2].ids).toEqual(['z']);
    });
  });