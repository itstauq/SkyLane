// Keep React behind a runtime-owned entrypoint so widgets always resolve the
// pinned runtime copy, and we can evolve this seam without changing imports.
module.exports = require("./node_modules/react");
