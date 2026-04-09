import {
  Card,
  CardContent,
  CardDescription,
  CardTitle,
  Image,
  Icon,
  Marquee,
  Overlay,
  RoundedRect,
  Section,
  Toolbar,
  ToolbarButton,
  useMedia,
} from "@skylane/api";

export default function Widget() {
  const {
    item,
    artwork,
    playbackState,
    availableActions,
    openSourceApp,
    previousTrack,
    togglePlayPause,
    nextTrack,
  } = useMedia();
  const title = item?.title?.trim() || "Nothing Playing";
  const secondaryText = item?.artist?.trim() || item?.album?.trim();
  const artworkSrc = artwork?.src;
  const hasArtwork = Boolean(artworkSrc);
  const isPlaying = playbackState === "playing";
  const hasAction = (action: string) => availableActions.includes(action);
  const controls = [
    {
      action: "previousTrack",
      symbol: "backward.fill",
      variant: "secondary",
      size: "md",
      onClick: previousTrack,
    },
    {
      action: "togglePlayPause",
      symbol: isPlaying ? "pause.fill" : "play.fill",
      variant: "default",
      size: "xl",
      onClick: togglePlayPause,
    },
    {
      action: "nextTrack",
      symbol: "forward.fill",
      variant: "secondary",
      size: "md",
      onClick: nextTrack,
    },
  ] as const;

  return (
    <Section spacing="lg" alignment="leading">
      <Card
        variant="accent"
        size="sm"
        strokeWidth={0}
        cornerRadius={16}
        onClick={hasAction("openSourceApp") ? openSourceApp : undefined}
      >
        {artworkSrc && (
          <Image
            src={artworkSrc}
            contentMode="fill"
            frame={{ maxWidth: Infinity, maxHeight: Infinity }}
            clipShape={{ type: "roundedRect", cornerRadius: 16 }}
          />
        )}

        <Overlay placement="bottom" inset="sm">
          <RoundedRect
            fill={hasArtwork ? "#140E19CC" : "#FFFFFF12"}
            strokeColor={hasArtwork ? "#FFFFFF12" : "#FFFFFF10"}
            strokeWidth={1}
            cornerRadius={14}
            frame={{ maxWidth: Infinity }}
          >
            <CardContent
              spacing="xs"
              alignment="center"
              inset="none"
              padding={{ top: 10, leading: 12, trailing: 12, bottom: 10 }}
            >
              {!hasArtwork && (
                <Icon symbol="music.note" size={18} weight="semibold" tone="accent" />
              )}
              <Marquee active={isPlaying}>
                <CardTitle alignment="center" lineClamp={1}>
                  {title}
                </CardTitle>
              </Marquee>
              {secondaryText && (
                <Marquee active={isPlaying}>
                  <CardDescription alignment="center" lineClamp={1}>
                    {secondaryText}
                  </CardDescription>
                </Marquee>
              )}
            </CardContent>
          </RoundedRect>
        </Overlay>
      </Card>

      <Toolbar spacing="lg" alignment="center">
        {controls.map((control) => {
          const isEnabled = hasAction(control.action);

          return (
            <ToolbarButton
              key={control.action}
              symbol={control.symbol}
              variant={control.variant}
              size={control.size}
              disabled={!isEnabled}
              onClick={isEnabled ? control.onClick : undefined}
            />
          );
        })}
      </Toolbar>
    </Section>
  );
}
