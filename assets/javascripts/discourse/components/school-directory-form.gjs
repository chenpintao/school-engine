import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { Input } from "@ember/component";
import { on } from "@ember/modifier";
import { ajax } from "discourse/lib/ajax";
import DButton from "discourse/ui-kit/d-button";
import { LinkTo } from "@ember/routing";
import { and, not } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";

/**
 * 同学录（找人工具）：统一搜索框。
 * 支持：真实姓名片段、拼音首字母（zs）、班级（3班）、届（2026）、组合（2026届3班）。
 * 结果只显示 昵称 + 届·班级，点击昵称进入个人主页。
 * staff 可导出 CSV（独立入口，全字段）。
 */
export default class SchoolDirectoryForm extends Component {
  @service currentUser;

  @tracked query = "";
  @tracked loading = false;
  @tracked searched = false;
  @tracked error = null;
  @tracked users = [];

  constructor() {
    super(...arguments);
    // 从 URL ?q= 恢复搜索词（返回上一页时），并自动重新搜索
    const q = this.args.controller?.q;
    if (q) {
      this.query = q;
      this.search();
    }
  }

  get isStaff() {
    return this.currentUser?.staff;
  }

  get exportUrl() {
    const q = this.query.trim();
    return "/school/directory.csv" + (q ? "?q=" + encodeURIComponent(q) : "");
  }

  @action
  keydown(event) {
    if (event.key === "Enter") {
      this.search();
    }
  }

  @action
  search() {
    this.loading = true;
    this.error = null;
    this.searched = true;
    const q = this.query.trim();
    // 同步到 URL query param（浏览器后退/前进时可恢复）
    if (this.args.controller) {
      this.args.controller.q = q || "";
    }
    const params = new URLSearchParams();
    if (q) params.set("q", q);
    ajax("/school/directory.json?" + params.toString())
      .then((data) => {
        this.users = data.users || [];
        this.loading = false;
      })
      .catch(() => {
        this.loading = false;
        this.error = i18n("school_engine.directory_load_error");
      });
  }

  <template>
    <div class="school-directory-page">
      <h2>{{i18n "school_engine.directory_title"}}</h2>

      <div class="school-directory-searchbar">
        <Input
          @type="text"
          @value={{this.query}}
          placeholder={{i18n "school_engine.directory_search_ph"}}
          {{on "keydown" this.keydown}}
        />
        <DButton @label="school_engine.directory_search" @type="primary" @action={{this.search}} @isLoading={{this.loading}} />
      </div>
      <p class="school-directory-hint">{{i18n "school_engine.directory_search_hint"}}</p>

      {{#if this.isStaff}}
        <p class="school-directory-export">
          <a href={{this.exportUrl}}>{{i18n "school_engine.directory_export"}}</a>
        </p>
      {{/if}}

      {{#if this.error}}
        <div class="school-auth-error">{{this.error}}</div>
      {{/if}}

      <div class="school-directory-results">
        {{#each this.users as |u|}}
          <div class="school-directory-card">
            <div class="school-directory-info">
              <div class="school-directory-name">
                <LinkTo @route="user" @model={{u.username}} class="school-directory-username-link">
                  <span class="school-directory-username">{{u.username}}</span>
                </LinkTo>
                {{#if u.display}}
                  <span class="school-directory-grade">{{u.display}}</span>
                {{/if}}
              </div>
            </div>
          </div>
        {{else}}
          {{#if (and this.searched (not this.loading))}}
            <p class="school-directory-empty">{{i18n "school_engine.directory_empty"}}</p>
          {{/if}}
        {{/each}}
      </div>
    </div>
  </template>
}
