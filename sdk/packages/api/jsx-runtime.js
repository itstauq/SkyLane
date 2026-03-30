// Keep JSX bound to the @notchapp/api namespace so we can evolve this seam
// later without changing widget build configuration or source imports.
module.exports = require("react/jsx-runtime");
