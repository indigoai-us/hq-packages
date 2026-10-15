import { companyName } from "../lib/labels.ts";
import { safeAssetUrl } from "../lib/theme.ts";
import { Link } from "../ui.tsx";
import type { HeaderProps } from "./types.ts";

/** Company logo or monogram and name, linking to the company page. */
export default function Header({ config }: HeaderProps) {
  const name = companyName(config.company);
  const logo = safeAssetUrl(config.theme.logo);
  return (
    <header class="bk-header">
      <Link href="/" class="bk-brand" aria-label={`${name} booking home`}>
        {logo ? (
          <img class="bk-logo" src={logo} alt="" width={28} height={28} />
        ) : (
          <span class="bk-monogram" aria-hidden="true">
            {name.slice(0, 1)}
          </span>
        )}
        <span class="bk-brand-name">{name}</span>
      </Link>
    </header>
  );
}
