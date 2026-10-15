// Sample override: copy to companies/{co}/booking/overrides/Header.tsx.
// It keeps the template header and adds a line under it. Overrides get the
// same props as the component they replace (see OVERRIDES.md) and must
// export the component as default.

import TemplateHeader from "@booking/components/Header.tsx";
import type { HeaderProps } from "@booking/components/types.ts";

export default function Header(props: HeaderProps) {
  return (
    <div class="acme-header" data-override="Header">
      <TemplateHeader {...props} />
      <p style={{ maxWidth: 1080, margin: "6px auto 0", padding: "0 24px", color: "var(--bk-muted)", fontSize: 14 }}>
        Northwind advisers answer within one business day.
      </p>
    </div>
  );
}
