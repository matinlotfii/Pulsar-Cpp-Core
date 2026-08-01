import { useEffect, useRef, useState } from "react";

function formatHeaderTime(date: Date) {
  return new Intl.DateTimeFormat("en-US", {
    hour: "numeric",
    minute: "2-digit",
    hour12: true
  }).format(date);
}

function formatHeaderDateTime(date: Date) {
  const pad = (value: number) => value.toString().padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function useHeaderClock() {
  const [now, setNow] = useState(() => new Date());
  const timerRef = useRef<number | null>(null);

  useEffect(() => {
    const update = () => setNow(new Date());
    const firstDelay = 1000 - (Date.now() % 1000);
    timerRef.current = window.setTimeout(() => {
      update();
      timerRef.current = window.setInterval(update, 1000);
    }, firstDelay);

    return () => {
      if (timerRef.current !== null) {
        window.clearTimeout(timerRef.current);
        window.clearInterval(timerRef.current);
      }
    };
  }, []);

  return {
    label: formatHeaderTime(now),
    dateTime: formatHeaderDateTime(now)
  };
}

export function HeaderClock() {
  const clock = useHeaderClock();
  return <time className="hmi-clock" dateTime={clock.dateTime}>{clock.label}</time>;
}
