// Validates JSON payload files against contract/v1/schema.json (JSON Schema
// draft 2020-12, ECMAScript regex patterns) with ajv.
// Usage: node tools/validate-contract.mjs <payload.json>...
import { readFileSync } from 'node:fs';
import { dirname, join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const schema = JSON.parse(readFileSync(join(root, 'contract/v1/schema.json'), 'utf8'));
const validate = new Ajv2020({ allErrors: true, strict: true, strictTuples: false }).compile(schema);

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error('usage: node tools/validate-contract.mjs <payload.json>...');
  process.exit(2);
}
let failed = 0;
for (const file of files) {
  if (validate(JSON.parse(readFileSync(file, 'utf8')))) {
    console.log('OK  ', basename(file));
  } else {
    failed++;
    // oneOf errors list every branch; the matching section's branch is the useful one.
    for (const e of validate.errors) console.log('FAIL', basename(file), e.instancePath || '/', e.message, JSON.stringify(e.params));
  }
}
console.log(failed ? `${failed} of ${files.length} payload(s) violate the contract` : `all ${files.length} payload(s) match the contract`);
process.exit(failed ? 1 : 0);
