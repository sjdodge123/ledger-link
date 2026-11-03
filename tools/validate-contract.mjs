// Validates JSON payload files against a pinned Raid Ledger contract (JSON
// Schema draft 2020-12, ECMAScript regex patterns) with ajv.
//   default:            contract/v1/schema.json (the ledgerlink/v1 export payload)
//   --dev-bridge <def>: contract/dev-bridge/v1/schema.json's $defs/<def>,
//                       e.g. ledgerlink-snapshot (the /rl dev snapshot)
// JSON Schema carries the shape only (types, enums, closed field sets, lengths,
// counts, patterns); the Zod-only refinements (size in bytes, GUID guard,
// name-bearing presence rows) are not in schema.json.
// Usage: node tools/validate-contract.mjs [--dev-bridge <def>] <payload.json>...
import { readFileSync } from 'node:fs';
import { dirname, join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const def = args[0] === '--dev-bridge' ? args[1] : undefined;
const files = def === undefined ? args : args.slice(2);
if (files.length === 0 || (args[0] === '--dev-bridge' && !def)) {
  console.error('usage: node tools/validate-contract.mjs [--dev-bridge <def>] <payload.json>...');
  process.exit(2);
}
const schemaFile = def === undefined ? 'contract/v1/schema.json' : 'contract/dev-bridge/v1/schema.json';
const schema = JSON.parse(readFileSync(join(root, schemaFile), 'utf8'));
// dev-bridge uses format "date-time"; every such field also carries an ISO
// pattern, so formats are not validated (no ajv-formats dependency).
const ajv = new Ajv2020({ allErrors: true, strict: true, strictTuples: false, validateFormats: false });
let validate;
if (def === undefined) {
  validate = ajv.compile(schema);
} else {
  if (!schema.$defs?.[def]) {
    console.error(`no $defs/${def} in ${schemaFile}`);
    process.exit(2);
  }
  ajv.addSchema(schema);
  validate = ajv.getSchema(`${schema.$id}#/$defs/${def}`);
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
