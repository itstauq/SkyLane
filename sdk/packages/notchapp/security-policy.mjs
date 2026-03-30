import Module from "node:module";

export const ALLOWED_BUILTIN_MODULES = Object.freeze([
  "buffer",
  "crypto",
  "events",
  "path",
  "querystring",
  "string_decoder",
  "url",
  "util",
]);

export const ALLOWED_BUILTIN_SPECIFIERS = Object.freeze(
  Module.builtinModules.filter((specifier) => {
    const withoutPrefix = specifier.startsWith("node:") ? specifier.slice(5) : specifier;
    const root = withoutPrefix.split("/")[0] || null;
    return root ? ALLOWED_BUILTIN_MODULES.includes(root) : false;
  })
);

export const ALLOWED_BUILTIN_EXTERNALS = Object.freeze(
  ALLOWED_BUILTIN_SPECIFIERS.flatMap((specifier) => [
    specifier,
    `node:${specifier}`,
  ])
);
