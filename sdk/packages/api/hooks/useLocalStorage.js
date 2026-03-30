const React = require("react");

const { LocalStorage } = require("../runtime");

function useLocalStorage(key, defaultValue) {
  const [value, setValue] = React.useState(() => {
    const storedValue = LocalStorage.getItem(key);
    return storedValue === undefined ? defaultValue : storedValue;
  });

  React.useEffect(() => {
    const storedValue = LocalStorage.getItem(key);
    setValue(storedValue === undefined ? defaultValue : storedValue);
  }, [key]);

  function setStoredValue(nextValue) {
    setValue((currentValue) => {
      const resolvedValue = typeof nextValue === "function"
        ? nextValue(currentValue)
        : nextValue;

      if (resolvedValue === undefined) {
        LocalStorage.removeItem(key);
        return defaultValue;
      }

      return LocalStorage.setItem(key, resolvedValue);
    });
  }

  return [value, setStoredValue];
}

module.exports = {
  useLocalStorage,
};
