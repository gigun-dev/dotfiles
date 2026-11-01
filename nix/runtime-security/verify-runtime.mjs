// Normal-input checks only; no exploit corpus and no external network requests.
import assert from 'node:assert/strict';
import { brotliCompressSync, brotliDecompressSync, brotliDecompress } from 'node:zlib';
import { promisify } from 'node:util';
import { createServer } from 'node:http';
const input = Buffer.from('Brotli runtime compatibility check.\n'.repeat(128));
const compressed = brotliCompressSync(input);
assert.deepEqual(brotliDecompressSync(compressed), input);
assert.deepEqual(await promisify(brotliDecompress)(compressed), input);
const server = createServer((_request, response) => {
  response.writeHead(200, { 'Content-Encoding': 'br', 'Content-Type': 'text/plain' });
  response.end(compressed);
});
await new Promise((resolve, reject) => {
  server.once('error', reject);
  server.listen(0, '127.0.0.1', resolve);
});
try {
  const response = await fetch(`http://127.0.0.1:${server.address().port}/`);
  assert.deepEqual(Buffer.from(await response.arrayBuffer()), input);
} finally {
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
}
console.log(JSON.stringify({ node: process.versions.node, bun: process.versions.bun ?? null,
  brotli: process.versions.brotli ?? null, sync: 'pass', async: 'pass', localHttpDecode: 'pass' }));
