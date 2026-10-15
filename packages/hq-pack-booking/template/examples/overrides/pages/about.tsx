// Sample extra page: overrides/pages/about.tsx becomes /about.
// Page components get { config } (the public config) and can use the
// template's components through @slots/ and @booking/.

import Footer from "@slots/Footer";
import Header from "@slots/Header";
import type { PublicConfig } from "@booking/lib/types.ts";
import { Link } from "@booking/ui.tsx";

export default function About({ config }: { config: PublicConfig }) {
  return (
    <div class="bk-page">
      <Header config={config} />
      <main id="main" class="bk-main bk-narrow">
        <h1 class="bk-display">About our calls</h1>
        <p class="bk-lede">Every call is with a named adviser. You can reschedule from the link in your confirmation email.</p>
        <Link href="/" class="bk-textlink">
          See open times
        </Link>
      </main>
      <Footer config={config} />
    </div>
  );
}
