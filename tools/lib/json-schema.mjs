// Minimal JSON Schema subset shared by the repository's configuration validators.
//
// It implements exactly the keywords the schema files in this repository use:
// $ref (local), type, enum, pattern, minLength, maxLength, minimum, maximum,
// minItems, items, required, properties and additionalProperties. Anything else
// in a schema is ignored, so a schema must not rely on keywords listed nowhere
// here — keep the schema and this walker in step.

function typeOf(value) {
    if (value === null) return "null";
    if (Array.isArray(value)) return "array";
    if (Number.isInteger(value)) return "integer";
    return typeof value;
}

export function validateSchema(value, schema, where = "$") {
    const errors = [];
    const fail = (at, message) => errors.push(`${at}: ${message}`);

    const deref = (node) => {
        if (!node || typeof node.$ref !== "string") return node;
        return node.$ref
            .replace(/^#\//, "")
            .split("/")
            .reduce((acc, key) => acc?.[key], schema);
    };

    const walk = (current, rawNode, at) => {
        const node = deref(rawNode);
        if (!node) return;
        const actual = typeOf(current);

        if (node.type !== undefined) {
            const allowed = Array.isArray(node.type) ? node.type : [node.type];
            const ok = allowed.some((t) => t === actual || (t === "number" && actual === "integer"));
            if (!ok) {
                fail(at, `expected type ${allowed.join(" or ")}, got ${actual}`);
                return;
            }
        }
        if (node.enum !== undefined && !node.enum.some((option) => option === current)) {
            fail(at, `value ${JSON.stringify(current)} is not one of ${JSON.stringify(node.enum)}`);
        }
        if (node.pattern !== undefined && typeof current === "string" && !new RegExp(node.pattern).test(current)) {
            fail(at, `value ${JSON.stringify(current)} does not match ${node.pattern}`);
        }
        if (node.minLength !== undefined && typeof current === "string" && current.length < node.minLength) {
            fail(at, `string is shorter than ${node.minLength} characters`);
        }
        if (node.maxLength !== undefined && typeof current === "string" && current.length > node.maxLength) {
            fail(at, `string is longer than ${node.maxLength} characters`);
        }
        if (node.minimum !== undefined && typeof current === "number" && current < node.minimum) {
            fail(at, `value ${current} is below the minimum ${node.minimum}`);
        }
        if (node.maximum !== undefined && typeof current === "number" && current > node.maximum) {
            fail(at, `value ${current} is above the maximum ${node.maximum}`);
        }
        if (actual === "array") {
            if (node.minItems !== undefined && current.length < node.minItems) {
                fail(at, `expected at least ${node.minItems} item(s), got ${current.length}`);
            }
            if (node.items !== undefined) current.forEach((item, index) => walk(item, node.items, `${at}[${index}]`));
        }
        if (actual === "object") {
            for (const key of node.required ?? []) {
                if (!Object.hasOwn(current, key)) fail(at, `missing required property "${key}"`);
            }
            for (const [key, child] of Object.entries(current)) {
                const childSchema = node.properties?.[key];
                if (childSchema === undefined) {
                    if (node.additionalProperties === false) fail(at, `unknown property "${key}"`);
                    continue;
                }
                walk(child, childSchema, `${at}.${key}`);
            }
        }
    };

    walk(value, schema, where);
    return errors;
}
