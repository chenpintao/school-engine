import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { Input } from "@ember/component";
import { ajax } from "discourse/lib/ajax";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

/**
 * 注入到 user-preferences-security outlet：自建改密码表单（原密码 + 新密码，无需邮箱验证）。
 * 原生 .pref-password 区由 SCSS :has() 隐藏。
 */
export default class SchoolChangePassword extends Component {
  @tracked currentPassword = "";
  @tracked newPassword = "";
  @tracked newPassword2 = "";
  @tracked submitting = false;
  @tracked error = null;
  @tracked success = false;

  @action
  submit() {
    this.error = null;
    this.success = false;
    if (!this.currentPassword) {
      this.error = i18n("school_engine.err_current_password");
      return;
    }
    if (this.newPassword.length < 8) {
      this.error = i18n("school_engine.err_password_short");
      return;
    }
    if (this.newPassword !== this.newPassword2) {
      this.error = i18n("school_engine.err_password_mismatch");
      return;
    }
    this.submitting = true;
    ajax("/school/change-password.json", {
      type: "POST",
      data: {
        current_password: this.currentPassword,
        new_password: this.newPassword,
      },
    })
      .then(() => {
        this.submitting = false;
        this.success = true;
        this.currentPassword = "";
        this.newPassword = "";
        this.newPassword2 = "";
      })
      .catch((e) => {
        this.submitting = false;
        this.error = (e.jqXHR?.responseJSON?.errors || []).join("；") || e.message;
      });
  }

  <template>
    <div class="school-change-password">
      <h3 class="school-change-password-title">{{i18n "school_engine.change_password_title"}}</h3>

      {{#if this.success}}
        <div class="school-profile-saved">{{i18n "school_engine.password_changed"}}</div>
      {{/if}}
      {{#if this.error}}
        <div class="school-auth-error">{{this.error}}</div>
      {{/if}}

      <div class="school-field">
        <label>{{i18n "school_engine.current_password"}}</label>
        <Input @type="password" @value={{this.currentPassword}} autocomplete="current-password" />
      </div>
      <div class="school-field">
        <label>{{i18n "school_engine.new_password"}}</label>
        <Input @type="password" @value={{this.newPassword}} autocomplete="new-password" />
      </div>
      <div class="school-field">
        <label>{{i18n "school_engine.confirm_password"}}</label>
        <Input @type="password" @value={{this.newPassword2}} autocomplete="new-password" />
      </div>
      <DButton
        @label="school_engine.change_password"
        @type="primary"
        @action={{this.submit}}
        @isLoading={{this.submitting}}
        class="school-pw-submit"
      />
    </div>
  </template>
}
