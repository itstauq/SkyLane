const { callRpc } = require("../runtime");

function openURL(url) {
  return callRpc("browser.open", { url });
}

module.exports = {
  openURL,
};
