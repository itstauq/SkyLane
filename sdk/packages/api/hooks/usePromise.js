const React = require("react");

function areDepsEqual(previousDeps, nextDeps) {
  if (!previousDeps || !nextDeps || previousDeps.length !== nextDeps.length) {
    return false;
  }

  for (let index = 0; index < previousDeps.length; index += 1) {
    if (!Object.is(previousDeps[index], nextDeps[index])) {
      return false;
    }
  }

  return true;
}

function usePromise(factory, deps = []) {
  const [state, setState] = React.useState({
    data: undefined,
    isLoading: true,
    error: undefined,
  });
  const controllerRef = React.useRef(null);
  const factoryRef = React.useRef(factory);
  const depsRef = React.useRef();

  factoryRef.current = factory;

  const revalidate = React.useCallback(() => {
    controllerRef.current?.abort();
    const controller = new AbortController();
    controllerRef.current = controller;

    setState((currentState) => ({
      data: currentState.data,
      isLoading: true,
      error: undefined,
    }));

    Promise.resolve()
      .then(() => factoryRef.current(controller.signal))
      .then((data) => {
        if (controller.signal.aborted || controllerRef.current !== controller) {
          return;
        }

        setState({
          data,
          isLoading: false,
          error: undefined,
        });
      })
      .catch((error) => {
        if (controller.signal.aborted || controllerRef.current !== controller) {
          return;
        }

        if (error?.name === "AbortError") {
          return;
        }

        setState({
          data: undefined,
          isLoading: false,
          error,
        });
      });
  }, []);

  React.useEffect(() => {
    const depsChanged = !areDepsEqual(depsRef.current, deps);
    depsRef.current = deps;
    if (!depsChanged) {
      return;
    }

    revalidate();
  });

  React.useEffect(() => {
    return () => {
      controllerRef.current?.abort();
    };
  }, []);

  return {
    data: state.data,
    isLoading: state.isLoading,
    error: state.error,
    revalidate,
  };
}

module.exports = {
  usePromise,
};
