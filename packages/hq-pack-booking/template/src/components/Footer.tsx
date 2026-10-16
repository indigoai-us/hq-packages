import type { FooterProps } from "./types.ts";

export default function Footer({ config }: FooterProps) {
  return (
    <footer class="bk-footer">
      <span>Scheduling by HQ Booking</span>
      {config.sandbox && <span class="bk-footer-sandbox">Sandbox: calendars, video and email are simulated.</span>}
    </footer>
  );
}
