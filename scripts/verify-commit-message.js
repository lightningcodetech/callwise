#!/usr/bin/env node
/*
 * Validates commit messages, pull request titles and branch names.
 *
 *   Branch:          <type>/<kebab-case-name>              e.g. feature/retry-engine
 *   Commit/PR title: [<type>/<kebab-case-name>] - <summary> e.g. [feature/retry-engine] - add sync retries
 *
 * Usage:
 *   node scripts/verify-commit-message.js <commit-msg-file>                 (husky commit-msg hook)
 *   node scripts/verify-commit-message.js --title "<title>" --branch "<branch>"   (CI, pull requests)
 */
const fs = require("fs");
const { execSync } = require("child_process");

const TYPES = ["feature", "bugfix", "hotfix", "refactor", "test", "docs", "ci", "chore", "release"];
const NAME = "[a-z0-9]+(?:-[a-z0-9]+)*";
const BRANCH_PATTERN = new RegExp(`^(?:${TYPES.join("|")})/${NAME}$`);
// The optional " (#123)" suffix is what GitHub appends to squash-merge commits.
const HEADER_PATTERN = new RegExp(`^\\[((?:${TYPES.join("|")})/${NAME})\\] - ([a-z].*?)(?: \\(#\\d+\\))?$`);
const MAX_SUMMARY_LENGTH = 72;
const SKIPPED_PREFIXES = ["Merge ", "Revert ", "fixup! ", "squash! "];

function currentBranch() {
    try {
        return execSync("git branch --show-current", { encoding: "utf8" }).trim();
    } catch {
        return "";
    }
}

function validateBranch(branch) {
    return BRANCH_PATTERN.test(branch)
        ? []
        : [`branch "${branch}" must be <type>/<kebab-case-name>, with type one of: ${TYPES.join(", ")}`];
}

function validateHeader(header, branch) {
    const match = HEADER_PATTERN.exec(header);
    if (!match) {
        return [
            `expected "[<type>/<branch-name>] - <summary>", got "${header}"`,
            `type is one of: ${TYPES.join(", ")}; the summary starts with a lower-case imperative verb`
        ];
    }
    const [, tag, summary] = match;
    const errors = [];
    if (summary.length > MAX_SUMMARY_LENGTH) {
        errors.push(`summary is ${summary.length} characters, max ${MAX_SUMMARY_LENGTH}`);
    }
    if (summary.endsWith(".")) {
        errors.push("summary must not end with a period");
    }
    if (branch && BRANCH_PATTERN.test(branch) && tag !== branch) {
        errors.push(`tag [${tag}] must match the current branch "${branch}"`);
    }
    return errors;
}

function parseArgs(argv) {
    const options = {};
    for (let i = 0; i < argv.length; i++) {
        if (argv[i] === "--title" || argv[i] === "--branch") {
            options[argv[i].slice(2)] = argv[++i] ?? "";
        } else {
            options.file = argv[i];
        }
    }
    return options;
}

function main() {
    const options = parseArgs(process.argv.slice(2));
    let errors;
    if (options.file) {
        const header = fs.readFileSync(options.file, "utf8").split("\n")[0].trim();
        if (SKIPPED_PREFIXES.some((prefix) => header.startsWith(prefix))) {
            return;
        }
        errors = validateHeader(header, currentBranch());
    } else {
        errors = [...validateBranch(options.branch ?? ""), ...validateHeader(options.title ?? "", options.branch)];
    }
    if (errors.length > 0) {
        console.error(errors.map((error) => `✖ ${error}`).join("\n"));
        console.error("See CONTRIBUTING.md#conventions");
        process.exit(1);
    }
}

main();
