import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { Input } from "@ember/component";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import DToggleSwitch from "discourse/ui-kit/d-toggle-switch";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";

const STATUSES = ["在读", "毕业生", "离校"];
const IDENTITIES = ["student", "teacher"];

/**
 * 校园管理页（/school/manage 唯一入口，staff 与班级管理组共用）。
 * 单页纵向呈现全部管理区块（无 tab、无独立子页面）：
 *  - 学籍管理：列表 + 筛选 + 编辑（毕业年份/班级/初中班级/状态/姓名，无视转班冷却）
 *  - 班级圈管理：圈列表（组/分类/人数/频道）+ 一键修正显示名
 * 权限由 manage-status 判定（staff 或班级管理组），数据 API 在后端二次校验。
 */
export default class SchoolAdminForm extends Component {
  @service currentUser;

  @tracked loading = false;
  @tracked allowed = null;
  @tracked error = null;
  @tracked notice = null;

  // 学籍列表
  @tracked users = [];
  @tracked total = 0;
  @tracked offset = 0;
  @tracked filterStatus = "all";
  @tracked filterIdentity = "all";
  @tracked query = "";

  // 编辑弹窗
  @tracked editing = null;
  @tracked editForm = {};
  @tracked resetCooldown = false;
  @tracked saving = false;

  // 班级圈
  @tracked classes = [];
  @tracked fixing = false;

  get hasMore() {
    return this.users.length < this.total;
  }

  constructor() {
    super();
    this.checkAllowed();
  }

  @action
  load() {
    this.loading = true;
    this.error = null;
    this.offset = 0;
    const data = {
      status: this.filterStatus,
      identity: this.filterIdentity,
      q: this.query.trim(),
      limit: 50,
      offset: 0,
    };
    ajax("/school/admin-users.json", { data })
      .then((res) => {
        this.users = res.users || [];
        this.total = res.total || 0;
        this.loading = false;
      })
      .catch((e) => {
        this.loading = false;
        popupAjaxError(e);
      });
  }

  @action
  loadMore() {
    if (!this.hasMore || this.loading) return;
    this.loading = true;
    const data = {
      status: this.filterStatus,
      identity: this.filterIdentity,
      q: this.query.trim(),
      limit: 50,
      offset: this.users.length,
    };
    ajax("/school/admin-users.json", { data })
      .then((res) => {
        this.users = this.users.concat(res.users || []);
        this.loading = false;
      })
      .catch((e) => {
        this.loading = false;
        popupAjaxError(e);
      });
  }

  @action
  checkAllowed() {
    ajax("/school/manage-status.json")
      .then((res) => {
        this.allowed = !!res.manage;
        if (this.allowed) {
          this.load();
          this.loadClasses();
        }
      })
      .catch(() => {
        this.allowed = false;
      });
  }

  @action
  loadClasses() {
    ajax("/school/admin-classes.json")
      .then((res) => {
        this.classes = res.classes || [];
      })
      .catch(popupAjaxError);
  }

  @action
  fixDisplays() {
    this.fixing = true;
    this.notice = null;
    ajax("/school/admin-fix-displays.json", { type: "POST" })
      .then(() => {
        this.fixing = false;
        this.notice = i18n("school_engine.admin_fix_done");
        this.loadClasses();
      })
      .catch((e) => {
        this.fixing = false;
        popupAjaxError(e);
      });
  }

  @action
  queryKeydown(event) {
    if (event.key === "Enter") {
      this.load();
    }
  }

  @action
  edit(u) {
    this.editing = u;
    this.editForm = {
      graduation_year: u.graduation_year || "",
      class_name: u.class_name || "",
      junior_class: u.junior_class || "",
      status: u.status || "",
      real_name: u.real_name || "",
      gender: u.gender || "",
    };
    this.resetCooldown = false;
  }

  @action
  formField(key, event) {
    this.editForm = { ...this.editForm, [key]: event.target.value };
  }

  @action
  filterSelect(key, event) {
    this[key] = event.target.value;
    this.load();
  }

  @action
  closeEdit() {
    this.editing = null;
  }

  @action
  toggleCooldown() {
    this.resetCooldown = !this.resetCooldown;
  }

  @action
  save() {
    if (!this.editing) return;
    this.saving = true;
    const data = { user_id: this.editing.id, ...this.editForm };
    data.reset_cooldown = this.resetCooldown ? "true" : "false";
    ajax("/school/admin-user.json", { type: "PUT", data })
      .then(() => {
        this.saving = false;
        this.editing = null;
        this.load();
      })
      .catch((e) => {
        this.saving = false;
        popupAjaxError(e);
      });
  }

  <template>
    <div class="school-admin-page">
      <h2>{{i18n "school_engine.admin_title"}}</h2>

      {{#if (eq this.allowed false)}}
        <p class="school-admin-denied">{{i18n "school_engine.admin_no_permission"}}</p>
      {{else if this.allowed}}
        {{#if this.notice}}
          <div class="school-profile-saved">{{this.notice}}</div>
        {{/if}}

        <section class="school-admin-section">
          <h3 class="school-admin-section-title">{{i18n "school_engine.admin_tab_users"}}</h3>

          <div class="school-admin-filters">
            <div class="school-field">
              <label>{{i18n "school_engine.admin_filter_status"}}</label>
              <select value={{this.filterStatus}} {{on "change" (fn this.filterSelect "filterStatus")}}>
                <option value="all">{{i18n "school_engine.admin_all"}}</option>
                {{#each STATUSES as |s|}}
                  <option value={{s}} selected={{eq this.filterStatus s}}>{{s}}</option>
                {{/each}}
              </select>
            </div>
            <div class="school-field">
              <label>{{i18n "school_engine.admin_filter_identity"}}</label>
              <select value={{this.filterIdentity}} {{on "change" (fn this.filterSelect "filterIdentity")}}>
                <option value="all">{{i18n "school_engine.admin_all"}}</option>
                {{#each IDENTITIES as |idt|}}
                  <option value={{idt}} selected={{eq this.filterIdentity idt}}>
                    {{if (eq idt "student") (i18n "school_engine.identity_student") (i18n "school_engine.identity_teacher")}}
                  </option>
                {{/each}}
              </select>
            </div>
            <div class="school-field">
              <label>{{i18n "school_engine.admin_search"}}</label>
              <Input
                @type="text"
                @value={{this.query}}
                {{on "keydown" this.queryKeydown}}
                placeholder={{i18n "school_engine.admin_search_placeholder"}}
              />
            </div>
            <DButton
              @label="school_engine.admin_search_btn"
              @type="primary"
              @action={{this.load}}
              @isLoading={{this.loading}}
            />
          </div>

          <table class="school-admin-table">
            <thead>
              <tr>
                <th>{{i18n "school_engine.admin_col_user"}}</th>
                <th>{{i18n "school_engine.admin_col_identity"}}</th>
                <th>{{i18n "school_engine.admin_col_real_name"}}</th>
                <th>{{i18n "school_engine.admin_col_class"}}</th>
                <th>{{i18n "school_engine.admin_col_status"}}</th>
                <th>{{i18n "school_engine.admin_col_display"}}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {{#each this.users as |u|}}
                <tr>
                  <td>{{u.username}}</td>
                  <td>
                    {{#if (eq u.identity "student")}}
                      {{i18n "school_engine.identity_student"}}
                    {{else}}
                      {{i18n "school_engine.identity_teacher"}}
                    {{/if}}
                  </td>
                  <td>{{u.real_name}}</td>
                  <td>
                    {{u.graduation_year}}届 · {{u.class_name}}
                    {{#if u.junior_class}}
                      <span class="school-admin-junior">（初中{{u.junior_class}}）</span>
                    {{/if}}
                  </td>
                  <td>{{u.status}}</td>
                  <td>{{u.display_class}}</td>
                  <td><DButton @icon="pencil" @action={{fn this.edit u}} class="btn-default" /></td>
                </tr>
              {{/each}}
            </tbody>
          </table>

          {{#if this.hasMore}}
            <DButton
              @label="school_engine.admin_load_more"
              @action={{this.loadMore}}
              class="btn-default school-admin-more"
            />
          {{/if}}
        </section>
      {{/if}}
    </div>

    {{#if this.editing}}
      <DModal
        @closeModal={{this.closeEdit}}
        @title={{this.editing.username}}
        class="school-admin-edit-modal"
      >
        <:body>
          <div class="school-field">
            <label>{{i18n "school_engine.graduation_year"}}</label>
            <Input
              @type="number"
              @value={{this.editForm.graduation_year}}
              {{on "input" (fn this.formField "graduation_year")}}
            />
            <p class="school-hint">{{i18n "school_engine.admin_gy_hint"}}</p>
          </div>
          <div class="school-field">
            <label>{{i18n "school_engine.class_name"}}</label>
            <Input
              @type="text"
              @value={{this.editForm.class_name}}
              {{on "input" (fn this.formField "class_name")}}
            />
          </div>
          <div class="school-field">
            <label>{{i18n "school_engine.junior_class"}}</label>
            <Input
              @type="text"
              @value={{this.editForm.junior_class}}
              {{on "input" (fn this.formField "junior_class")}}
            />
          </div>
          <div class="school-field">
            <label>{{i18n "school_engine.admin_status"}}</label>
            <select value={{this.editForm.status}} {{on "change" (fn this.formField "status")}}>
              <option value=""></option>
              {{#each STATUSES as |s|}}
                <option value={{s}} selected={{eq this.editForm.status s}}>{{s}}</option>
              {{/each}}
            </select>
          </div>
          <div class="school-field">
            <label>{{i18n "school_engine.real_name"}}</label>
            <Input
              @type="text"
              @value={{this.editForm.real_name}}
              {{on "input" (fn this.formField "real_name")}}
            />
          </div>
          <div class="school-field">
            <label>{{i18n "school_engine.gender"}}</label>
            <select value={{this.editForm.gender}} {{on "change" (fn this.formField "gender")}}>
              <option value=""></option>
              <option value="男" selected={{eq this.editForm.gender "男"}}>男</option>
              <option value="女" selected={{eq this.editForm.gender "女"}}>女</option>
            </select>
          </div>
          <div class="school-field school-field-toggle">
            <DToggleSwitch
              @state={{this.resetCooldown}}
              @label="school_engine.admin_reset_cooldown"
              {{on "click" this.toggleCooldown}}
            />
          </div>
        </:body>
        <:footer>
          <DButton
            @label="school_engine.admin_save"
            @type="primary"
            @action={{this.save}}
            @isLoading={{this.saving}}
          />
          <DButton @label="school_engine.cancel" @action={{this.closeEdit}} class="btn-default" />
        </:footer>
      </DModal>
    {{/if}}
  </template>
}
