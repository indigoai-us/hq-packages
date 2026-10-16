import EventList from "@slots/EventList";
import Footer from "@slots/Footer";
import Header from "@slots/Header";
import { useApp } from "../context.ts";
import { companyName } from "../lib/labels.ts";
import { carryParams } from "../lib/params.ts";
import { useLocation } from "../lib/router.ts";
import { Icon, Link } from "../ui.tsx";

export function CompanyPage() {
  const app = useApp();
  const loc = useLocation();
  const { config } = app;
  const form = config.routingForms[0];
  const carried = carryParams(loc.search);
  return (
    <div class="bk-page">
      {!app.embed.embedded && <Header config={config} />}
      <main id="main" class="bk-main bk-narrow">
        <h1 class="bk-display">Book time with {companyName(config.company)}</h1>
        <p class="bk-lede">Pick a meeting type to see open times in your time zone.</p>
        <EventList eventTypes={config.eventTypes} hrefFor={(ev) => `/${encodeURIComponent(ev.id)}${carried}`} />
        {form && (
          <Link href={`/route/${encodeURIComponent(form.id)}${carried}`} class="bk-route-entry">
            <span class="bk-route-icon" aria-hidden="true">
              <Icon name="route" size={18} />
            </span>
            <span>
              <span class="bk-route-title">Not sure which one fits?</span>
              <span class="bk-route-text">
                Answer {form.questions.length === 1 ? "one quick question" : `${form.questions.length} quick questions`} and we'll pick the right meeting.
              </span>
            </span>
            <Icon name="arrow" size={16} />
          </Link>
        )}
      </main>
      <Footer config={config} />
    </div>
  );
}
