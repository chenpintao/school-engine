import Component from "@glimmer/component";

/**
 * 注入到 before-user-profile-bio outlet：在个人主页 bio 前显示性别 + 爱好标签。
 */
export default class SchoolHobbiesTags extends Component {
  get user() {
    return this.args.outletArgs?.model;
  }

  get gender() {
    return this.user?.custom_fields?.gender || "";
  }

  get hobbies() {
    const raw = this.user?.custom_fields?.hobbies || "";
    return raw
      .split(",")
      .map((s) => s.trim())
      .filter((s) => s.length > 0);
  }

  get hasContent() {
    return this.gender || this.hobbies.length > 0;
  }

  <template>
    {{#if this.hasContent}}
      <div class="school-profile-tags">
        {{#if this.gender}}
          <span class="school-profile-tag school-profile-tag-gender">{{this.gender}}</span>
        {{/if}}
        {{#each this.hobbies as |h|}}
          <span class="school-profile-tag">{{h}}</span>
        {{/each}}
      </div>
    {{/if}}
  </template>
}
