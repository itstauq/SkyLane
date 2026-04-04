import { useState } from "react";

import {
  Checkbox,
  IconButton,
  Inline,
  Input,
  Row,
  ScrollView,
  Spacer,
  Stack,
  Text,
  useLocalStorage,
} from "@notchapp/api";

function normalizeItems(value) {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.flatMap((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      return [];
    }

    const id = typeof item.id === "string" ? item.id : "";
    const title = typeof item.title === "string" ? item.title.trim() : "";
    const checked = item.checked === true;

    if (!id || !title) {
      return [];
    }

    return [{ id, title, checked }];
  });
}

function createItem(title) {
  const trimmed = title.trim();
  if (!trimmed) {
    return null;
  }

  return {
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    title: trimmed,
    checked: false,
  };
}

function normalizeDraft(value) {
  return typeof value === "string" ? value : "";
}

function useCaptureItems() {
  const [storedItems, setStoredItems] = useLocalStorage("items", []);
  const items = normalizeItems(storedItems);

  function setItems(update) {
    setStoredItems((current) => update(normalizeItems(current)));
  }

  return [items, setItems];
}

function CaptureRow({ item, onToggle, onDelete }) {
  return (
    <Row onPress={() => onToggle(item.id)}>
      <Inline spacing={8} alignment="center">
        <Checkbox checked={item.checked} onPress={() => onToggle(item.id)} />
        <Text
          tone={item.checked ? "tertiary" : "secondary"}
          strikethrough={item.checked}
          lineClamp={1}
        >
          {item.title}
        </Text>
        <Spacer />
        <IconButton
          symbol="trash"
          tone="secondary"
          size="large"
          onPress={() => onDelete(item.id)}
        />
      </Inline>
    </Row>
  );
}

export default function Widget({ environment }) {
  const [items, setItems] = useCaptureItems();
  const [draft, setDraft] = useState("");

  console.info(
    `render capture widget span=${environment.span} items=${items.length} draft=${draft.length}`
  );

  function submitDraft(rawValue) {
    const nextDraft = normalizeDraft(rawValue);
    const nextItem = createItem(nextDraft);
    if (!nextItem) {
      setDraft(nextDraft);
      return;
    }

    setItems((current) => [nextItem, ...current]);
    setDraft("");
  }

  function toggleItem(id) {
    setItems((current) =>
      current.map((item) =>
        item.id === id ? { ...item, checked: !item.checked } : item
      )
    );
  }

  function deleteItem(id) {
    setItems((current) => current.filter((item) => item.id !== id));
  }

  return (
    <Stack spacing={10}>
      <Input
        value={draft}
        placeholder="Press ↵ to capture another item"
        onChange={(payload) => setDraft(normalizeDraft(payload?.value))}
        onSubmit={(payload) => submitDraft(payload?.value)}
      />

      {items.length === 0 ? (
        <Text tone="tertiary">Nothing captured yet.</Text>
      ) : (
        <ScrollView spacing={8}>
          {items.map((item) => (
            <CaptureRow
              key={item.id}
              item={item}
              onToggle={toggleItem}
              onDelete={deleteItem}
            />
          ))}
        </ScrollView>
      )}
    </Stack>
  );
}
