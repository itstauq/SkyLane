import { Button, Stack, Text } from "@notchapp/api";

export const initialState = {
  count: 0,
};

export const actions = {
  increment(state) {
    return {
      ...state,
      count: (state?.count ?? 0) + 1,
    };
  },
};

export default function Widget({ environment, state, logger }) {
  logger.info(`render hello widget span=${environment.span} count=${state.count}`);

  return (
    <Stack spacing={10}>
      <Text>{`Hello from the widget runtime`}</Text>
      <Text>{`Span ${environment.span} • Count ${state.count}`}</Text>
      <Button title="Increment" action="increment" />
    </Stack>
  );
}
