import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { Input } from "@ember/component";
import { on } from "@ember/modifier";
import { ajax } from "discourse/lib/ajax";
import { concat } from "@ember/helper";
import DButton from "discourse/ui-kit/d-button";
import { LinkTo } from "@ember/routing";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";

/**
 * 同学录页面：级/性别筛选 + 昵称/爱好搜索，隐私设计不显示真实姓名与班级。
 * 管理员可导出 CSV（含全字段）。
 */
export default class SchoolDirectoryForm extends Component {
  @service currentUser;

  @tracked level = "";
  @tracked gender = "";
  @tracked usernameQuery = "";
  @tracked hobbyQuery = "";
  @tracked includeGraduates = false;
  @tracked loading = false;
  @tracked error = null;
  @tracked users = [];
  @tracked options = { levels: [], genders: [] };

  get levelOptions() {
    return this.options.levels || [];
  }

  get genderOptions() {
    return this.options.genders || [];
  }

  get isStaff() {
    return this.currentUser?.staff;
  }

  get exportUrl() {
    const params = new URLSearchParams();
    if (this.level) params.set("level", this.level);
    if (this.gender) params.set("gender", this.gender);
    if (this.usernameQuery.trim()) params.set("username", this.usernameQuery.trim());
    if (this.hobbyQuery.trim()) params.set("hobby", this.hobbyQuery.trim());
    const qs = params.toString();
    return "/school/directory.csv" + (qs ? "?" + qs : "");
  }

  constructor() {
    super(...arguments);
    // 进入页面即加载列表 + 拉取所有筛选项
    this.search();
  }

  @action
  search() {
    this.loading = true;
    this.error = null;
    const params = new URLSearchParams();
    if (this.level) params.set("level", this.level);
    if (this.gender) params.set("gender", this.gender);
    if (this.usernameQuery.trim()) params.set("username", this.usernameQuery.trim());
    if (this.hobbyQuery.trim()) params.set("hobby", this.hobbyQuery.trim());
    if (this.includeGraduates) params.set("include_graduates", "true");
    ajax("/school/directory.json?" + params.toString())
      .then((data) => {
        this.users = data.users || [];
        if (data.options) this.options = data.options;
        this.loading = false;
      })
      .catch(() => {
        this.loading = false;
        this.error = i18n("school_engine.directory_load_error");
      });
  }

  @action
  levelChanged(event) {
    this.level = event.target.value;
  }

  @action
  genderChanged(event) {
    this.gender = event.target.value;
  }

  @action
  graduatesChanged(event) {
    this.includeGraduates = event.target.checked;
  }

  contactItems(contact) {
    return Object.keys(contact || {}).map((k) => ({ key: k, value: contact[k] }));
  }

  avatarUrl(template, size = 64) {
    return template ? template.replace("{size}", String(size)) : null;
  }

  <template>
    <div class="school-directory-page">
      <h2>{{i18n "school_engine.directory_title"}}</h2>

      {{#if this.error}}
        <div class="school-auth-error">{{this.error}}</div>
      {{/if}}

      <div class="school-directory-filters">
        <div class="school-field">
          <label>{{i18n "school_engine.directory_level"}}</label>
          <select value={{this.level}} {{on "change" this.levelChanged}}>
            <option value="">{{i18n "school_engine.directory_all"}}</option>
            {{#each this.levelOptions as |l|}}
              <option value={{l}} selected={{eq this.level l}}>{{l}}级</option>
            {{/each}}
          </select>
        </div>
        <div class="school-field">
          <label>{{i18n "school_engine.directory_gender"}}</label>
          <select value={{this.gender}} {{on "change" this.genderChanged}}>
            <option value="">{{i18n "school_engine.directory_all"}}</option>
            {{#each this.genderOptions as |g|}}
              <option value={{g}} selected={{eq this.gender g}}>{{g}}</option>
            {{/each}}
          </select>
        </div>
        <div class="school-field">
          <label>{{i18n "school_engine.directory_username"}}</label>
          <Input @type="text" @value={{this.usernameQuery}} placeholder={{i18n "school_engine.directory_username_ph"}} />
        </div>
        <div class="school-field">
          <label>{{i18n "school_engine.directory_hobby"}}</label>
          <Input @type="text" @value={{this.hobbyQuery}} placeholder={{i18n "school_engine.directory_hobby_ph"}} />
        </div>
        <div class="school-directory-check">
          <label>
            <input type="checkbox" checked={{this.includeGraduates}} {{on "change" this.graduatesChanged}} />
            {{i18n "school_engine.directory_include_graduates"}}
          </label>
        </div>
        <DButton @label="school_engine.directory_search" @type="primary" @action={{this.search}} @isLoading={{this.loading}} />
      </div>

      {{#if this.isStaff}}
        <p class="school-directory-export">
          <a href={{this.exportUrl}}>{{i18n "school_engine.directory_export"}}</a>
        </p>
      {{/if}}

      <div class="school-directory-results">
        {{#each this.users as |u|}}
          <div class="school-directory-card">
            <LinkTo @route="user" @model={{u.username}} class="school-directory-user-link">
              {{#if u.avatar_template}}
                <img class="school-directory-avatar" src={{this.avatarUrl u.avatar_template}} alt="" />
              {{/if}}
            </LinkTo>
            <div class="school-directory-info">
              <div class="school-directory-name">
                <LinkTo @route="user" @model={{u.username}} class="school-directory-username-link">
                  <span class="school-directory-username">{{u.username}}</span>
                </LinkTo>
                <span class="school-directory-grade">{{u.level}}级</span>
                {{#if u.gender}}<span class="school-directory-gender">{{u.gender}}</span>{{/if}}
              </div>
              {{#if u.hobbies.length}}
                <div class="school-directory-tags">
                  {{#each u.hobbies as |h|}}
                    <span class="school-directory-tag">{{h}}</span>
                  {{/each}}
                </div>
              {{/if}}
              {{#if u.bio}}<p class="school-directory-bio">{{u.bio}}</p>{{/if}}
              {{#if u.contact}}
                <div class="school-directory-contact">
                  {{#each (this.contactItems u.contact) as |item|}}
                    <span class="school-directory-contact-item">{{i18n (concat "school_engine.contact_" item.key)}}: {{item.value}}</span>
                  {{/each}}
                </div>
              {{/if}}
            </div>
          </div>
        {{else}}
          {{#unless this.loading}}
            <p class="school-directory-empty">{{i18n "school_engine.directory_empty"}}</p>
          {{/unless}}
        {{/each}}
      </div>
    </div>
  </template>
}
