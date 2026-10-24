import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { Input } from "@ember/component";
import { on } from "@ember/modifier";
import { fn, get } from "@ember/helper";
import { ajax } from "discourse/lib/ajax";
import DButton from "discourse/ui-kit/d-button";
import DToggleSwitch from "discourse/ui-kit/d-toggle-switch";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";

const CONTACT_FIELDS = ["phone", "real_email", "wechat", "qq", "other_social"];

/**
 * 个人资料表单（注入到 user-preferences-profile outlet）：
 * 学籍卡片、自助转班、性别/爱好、联系方式（含每项公开/隐藏开关）。
 */
export default class SchoolProfileForm extends Component {
  @service dialog;
  @service currentUser;

  @tracked loading = true;
  @tracked saving = false;
  @tracked saved = false;
  @tracked error = null;

  @tracked username = "";
  @tracked fields = {}; // 学籍字段
  @tracked gradeDisplay = "";
  @tracked gender = "";
  @tracked hobbies = "";
  @tracked contact = {}; // 联系方式
  @tracked visibility = {}; // 可见性
  @tracked originalContact = {}; // 首次填写检测用

  // 自助转班（§6.2）
  @tracked transferClass = "";
  @tracked transferSubmitting = false;
  @tracked transferError = null;
  @tracked transferSuccess = null;

  get classOptions() {
    return ["1班", "2班", "3班", "4班", "5班", "6班"];
  }

  @action
  transferClassChanged(event) {
    this.transferClass = event.target.value;
  }

  @action
  genderChanged(event) {
    this.gender = event.target.value;
  }

  @action
  submitTransfer() {
    this.transferError = null;
    this.transferSuccess = null;
    if (!this.transferClass) {
      this.transferError = i18n("school_engine.err_choose_class");
      return;
    }
    this.transferSubmitting = true;
    ajax("/school/transfer-class.json", {
      type: "POST",
      data: { class_name: this.transferClass },
    })
      .then(() => {
        this.transferSubmitting = false;
        this.transferSuccess = i18n("school_engine.transfer_success");
        this.load();
      })
      .catch((e) => {
        this.transferSubmitting = false;
        this.transferError = (e.jqXHR?.responseJSON?.errors || []).join("；") || e.message;
      });
  }

  constructor() {
    super(...arguments);
    this.load();
  }

  get contactDefs() {
    return CONTACT_FIELDS.map((key) => ({
      key,
      label: i18n(`school_engine.contact_${key}`),
      placeholder: i18n(`school_engine.contact_${key}_ph`),
    }));
  }

  @action
  load() {
    this.loading = true;
    ajax("/school/profile.json")
      .then((data) => {
        this.username = data.username;
        this.fields = data.fields || {};
        this.gradeDisplay = data.grade_display || "";
        this.gender = data.gender || "";
        this.hobbies = data.hobbies || "";
        this.contact = { ...(data.contact || {}) };
        this.visibility = { ...(data.visibility || {}) };
        this.originalContact = { ...(data.contact || {}) };
        this.loading = false;
      })
      .catch(() => {
        this.error = i18n("school_engine.profile_load_error");
        this.loading = false;
      });
  }

  @action
  toggleVisibility(key) {
    // @tracked 对象属性级修改不触发渲染，必须整体替换
    this.visibility = { ...this.visibility, [key]: !this.visibility[key] };
  }

  @action
  updateContact(key, event) {
    // 同上：@tracked 对象需整体替换才能触发重新渲染
    this.contact = { ...this.contact, [key]: event.target.value };
  }

  // 保存：首次填写联系方式时弹确认（需求 §1.4）
  @action
  save() {
    this.error = null;
    this.saved = false;

    const firstTimeFilled = CONTACT_FIELDS.some(
      (k) => !this.originalContact[k] && this.contact[k]?.trim()
    );

    const doSave = () => {
      this.saving = true;
      ajax("/school/profile.json", {
        type: "PUT",
        data: {
          contact: this.contact,
          visibility: this.visibility,
          gender: this.gender,
          hobbies: this.hobbies,
        },
      })
        .then(() => {
          this.saving = false;
          this.saved = true;
          this.originalContact = { ...this.contact };
          setTimeout(() => (this.saved = false), 3000);
        })
        .catch((e) => {
          this.saving = false;
          this.error = (e.jqXHR?.responseJSON?.errors || []).join("；") || e.message;
        });
    };

    if (firstTimeFilled) {
      this.dialog.confirm({
        message: i18n("school_engine.contact_confirm_message"),
        confirmButtonLabel: "school_engine.confirm",
        didConfirm: doSave,
      });
    } else {
      doSave();
    }
  }

  <template>
    <div class="school-profile-page">
      {{#if this.loading}}
        <div class="school-profile-loading">{{i18n "school_engine.loading"}}</div>
      {{else}}
        {{#if this.error}}
          <div class="school-auth-error">{{this.error}}</div>
        {{/if}}
        {{#if this.saved}}
          <div class="school-profile-saved">{{i18n "school_engine.saved"}}</div>
        {{/if}}

        {{! 学籍卡片 }}
        <div class="school-profile-card">
          <h2>{{i18n "school_engine.profile_school_title"}}</h2>
          <div class="school-confirm-list">
            <div class="school-confirm-row">
              <span class="school-confirm-k">{{i18n "school_engine.username"}}</span>
              <span class="school-confirm-v">{{this.username}}</span>
            </div>
            <div class="school-confirm-row">
              <span class="school-confirm-k">{{i18n "school_engine.profile_grade"}}</span>
              <span class="school-confirm-v">{{this.gradeDisplay}}</span>
            </div>
            {{#if this.fields.real_name}}
              <div class="school-confirm-row">
                <span class="school-confirm-k">{{i18n "school_engine.real_name"}}</span>
                <span class="school-confirm-v">{{this.fields.real_name}}</span>
              </div>
            {{/if}}
            {{#if this.fields.graduation_year}}
              <div class="school-confirm-row">
                <span class="school-confirm-k">{{i18n "school_engine.graduation_year"}}</span>
                <span class="school-confirm-v">{{this.fields.graduation_year}} 届</span>
              </div>
            {{/if}}
            {{#if this.fields.status}}
              <div class="school-confirm-row">
                <span class="school-confirm-k">{{i18n "school_engine.profile_status"}}</span>
                <span class="school-confirm-v">{{this.fields.status}}</span>
              </div>
            {{/if}}
          </div>
        </div>

        {{! 自助转班（§6.2）}}
        <div class="school-profile-card">
          <h2>{{i18n "school_engine.transfer_title"}}</h2>
          <p class="school-hint">{{i18n "school_engine.transfer_hint"}}</p>
          {{#if this.transferError}}
            <div class="school-auth-error">{{this.transferError}}</div>
          {{/if}}
          {{#if this.transferSuccess}}
            <div class="school-profile-saved">{{this.transferSuccess}}</div>
          {{/if}}
          <div class="school-transfer-row">
            <select value={{this.transferClass}} {{on "change" this.transferClassChanged}}>
              <option value="">{{i18n "school_engine.transfer_select"}}</option>
              {{#each this.classOptions as |c|}}
                <option value={{c}} selected={{eq this.transferClass c}}>{{c}}</option>
              {{/each}}
            </select>
            <DButton
              @label="school_engine.transfer_submit"
              @type="primary"
              @action={{this.submitTransfer}}
              @isLoading={{this.transferSubmitting}}
            />
          </div>
        </div>

        {{! 性别 / 爱好（生成标签，展示在个人主页与同学录）}}
        <div class="school-profile-card">
          <h2>{{i18n "school_engine.profile_personal_title"}}</h2>
          <div class="school-field">
            <label>{{i18n "school_engine.gender"}}</label>
            <select value={{this.gender}} {{on "change" this.genderChanged}}>
              <option value="">{{i18n "school_engine.gender_placeholder"}}</option>
              <option value="男">{{i18n "school_engine.gender_male"}}</option>
              <option value="女">{{i18n "school_engine.gender_female"}}</option>
            </select>
          </div>
          <div class="school-field">
            <label>{{i18n "school_engine.hobbies"}}</label>
            <Input
              @type="text"
              @value={{this.hobbies}}
              placeholder={{i18n "school_engine.hobbies_ph"}}
            />
            <p class="school-hint">{{i18n "school_engine.hobbies_hint"}}</p>
          </div>
        </div>

        {{! 联系方式 }}
        <div class="school-profile-card">
          <h2>{{i18n "school_engine.profile_contact_title"}}</h2>
          <p class="school-hint">{{i18n "school_engine.profile_contact_hint"}}</p>
          {{#each this.contactDefs as |def|}}
            <div class="school-contact-row">
              <div class="school-field">
                <label>{{def.label}}</label>
                <Input @type="text" @value={{get this.contact def.key}} placeholder={{def.placeholder}} {{on "input" (fn this.updateContact def.key)}} />
              </div>
              <div class="school-visibility">
                <DToggleSwitch
                  @state={{get this.visibility def.key}}
                  @label={{if (get this.visibility def.key) "school_engine.visible" "school_engine.hidden"}}
                  {{on "click" (fn this.toggleVisibility def.key)}}
                />
              </div>
            </div>
          {{/each}}
          <DButton
            @label="school_engine.save"
            @type="primary"
            @action={{this.save}}
            @isLoading={{this.saving}}
            class="school-submit-btn"
          />
        </div>
      {{/if}}
    </div>
  </template>
}
