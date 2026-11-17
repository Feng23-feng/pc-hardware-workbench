import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";

const schemaRoot = resolve(import.meta.dirname, "..");
const commonId =
  "https://skilldock.local/contracts/source-hosted-shared-task/v1/common.schema.json";
const requestsId =
  "https://skilldock.local/contracts/source-hosted-shared-task/v1/requests.schema.json";
const responsesId =
  "https://skilldock.local/contracts/source-hosted-shared-task/v1/responses.schema.json";
const errorsId =
  "https://skilldock.local/contracts/source-hosted-shared-task/v1/errors.schema.json";
const receiptId =
  "https://skilldock.local/contracts/source-hosted-shared-task/v1/idempotency-receipt.schema.json";

function readSchema(name) {
  return JSON.parse(readFileSync(resolve(schemaRoot, name), "utf8"));
}

export function createContractValidator() {
  const ajv = new Ajv2020({
    allErrors: true,
    strict: false,
    validateFormats: true,
  });
  addFormats(ajv);
  for (const schema of [
    readSchema("common.schema.json"),
    readSchema("errors.schema.json"),
    readSchema("requests.schema.json"),
    readSchema("responses.schema.json"),
    readSchema("idempotency-receipt.schema.json"),
  ]) {
    ajv.addSchema(schema);
  }

  const requestValidators = new Map(
    ["snapshot", "pull", "publish", "ack", "claimLease", "releaseLease"].map(
      (name) => [name, ajv.getSchema(`${requestsId}#/$defs/${name}Request`)],
    ),
  );
  const responseValidators = new Map(
    [
      "snapshot",
      "pull",
      "publish",
      "ack",
      "claimLease",
      "releaseLease",
      "error",
    ].map((name) => [
      name,
      ajv.getSchema(`${responsesId}#/$defs/${name}Response`),
    ]),
  );
  const capabilityValidator = ajv.getSchema(
    `${commonId}#/$defs/mailboxCapability`,
  );
  const leaseControlValidator = ajv.getSchema(
    `${commonId}#/$defs/leaseControlCapability`,
  );
  const executionStateValidator = ajv.getSchema(
    `${commonId}#/$defs/executionState`,
  );
  const receiptValidator = ajv.getSchema(receiptId);

  for (const [name, validator] of [
    ...requestValidators,
    ...responseValidators,
    ["capability", capabilityValidator],
    ["leaseControl", leaseControlValidator],
    ["executionState", executionStateValidator],
    ["receipt", receiptValidator],
  ]) {
    if (!validator) {
      throw new Error(`Schema validator was not compiled: ${name}`);
    }
  }

  return Object.freeze({
    validateRequest(name, value) {
      const validator = requestValidators.get(name);
      if (!validator) {
        throw new TypeError(`Unknown request schema: ${name}`);
      }
      return {
        valid: Boolean(validator(value)),
        errors: validator.errors ? structuredClone(validator.errors) : [],
      };
    },
    validateResponse(name, value) {
      const validator = responseValidators.get(name);
      if (!validator) {
        throw new TypeError(`Unknown response schema: ${name}`);
      }
      return {
        valid: Boolean(validator(value)),
        errors: validator.errors ? structuredClone(validator.errors) : [],
      };
    },
    validateCapability(value) {
      return {
        valid: Boolean(capabilityValidator(value)),
        errors: capabilityValidator.errors
          ? structuredClone(capabilityValidator.errors)
          : [],
      };
    },
    validateLeaseControl(value) {
      return {
        valid: Boolean(leaseControlValidator(value)),
        errors: leaseControlValidator.errors
          ? structuredClone(leaseControlValidator.errors)
          : [],
      };
    },
    validateExecutionState(value) {
      return {
        valid: Boolean(executionStateValidator(value)),
        errors: executionStateValidator.errors
          ? structuredClone(executionStateValidator.errors)
          : [],
      };
    },
    validateReceipt(value) {
      return {
        valid: Boolean(receiptValidator(value)),
        errors: receiptValidator.errors
          ? structuredClone(receiptValidator.errors)
          : [],
      };
    },
    ids: Object.freeze({
      common: commonId,
      requests: requestsId,
      responses: responsesId,
      errors: errorsId,
      receipt: receiptId,
    }),
  });
}
