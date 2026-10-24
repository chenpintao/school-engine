import Component from "@glimmer/component";
import { i18n } from "discourse-i18n";

/**
 * 注入到 before-user-profile-bio outlet：在个人主页展示该用户已填写的联系方式。
 * 数据来自 UserSerializer#school_contacts（后端已按公开开关/本人/staff 过滤）。
 */
export default class SchoolContacts extends Component {
  get user() {
    return this.args.outletArgs?.model;
  }

  get items() {
    const contacts = this.user?.school_contacts;
    if (!contacts) {
      return [];
    }
    return Object.keys(contacts)
      .filter((k) => contacts[k])
      .map((k) => ({
        key: k,
        label: i18n(`school_engine.contact_${k}`),
        value: contacts[k],
      }));
  }

  <template>
    {{#if this.items.length}}
      <div class="school-profile-contacts">
        {{#each this.items as |item|}}
          <span class="school-profile-contact-item">
            <span class="school-profile-contact-label">{{item.label}}</span>
            <span class="school-profile-contact-value">{{item.value}}</span>
          </span>
        {{/each}}
      </div>
    {{/if}}
  </template>
}
