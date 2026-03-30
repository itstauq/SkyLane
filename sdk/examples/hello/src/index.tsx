import { Button, Stack, Text, useLocalStorage } from "@notchapp/api";

export default function Widget({ environment, logger }) {
  const [count, setCount] = useLocalStorage("count", 0);

  logger.info(`render hello widget span=${environment.span} count=${count}`);

  return (
    <Stack spacing={10}>
      <Text>Hello from NotchApp</Text>
      <Text tone="secondary">{`Span ${environment.span} • Count ${count}`}</Text>
      <Button title="Increment" onPress={() => setCount((value) => value + 1)} />
    </Stack>
  );
}
