const { usePromise } = require("./usePromise");

function useFetch(url, options = {}) {
  const { parseJson = true, ...requestInit } = options;

  return usePromise(async (signal) => {
    const response = await fetch(url, {
      ...requestInit,
      signal,
    });

    if (!response.ok) {
      throw new Error(`Request failed with status ${response.status}`);
    }

    return parseJson ? response.json() : response.text();
  }, [url, JSON.stringify(options)]);
}

module.exports = {
  useFetch,
};
