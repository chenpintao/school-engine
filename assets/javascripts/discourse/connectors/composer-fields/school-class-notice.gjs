import Component from "@glimmer/component";
import { service } from "@ember/service";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import DToggleSwitch from "discourse/ui-kit/d-toggle-switch";
import { i18n } from "discourse-i18n";

/**
 * 班级通知开关：staff 在班级圈分类（xx-class-* / cz-class-*）发新主题时可见。
 * 写入 composer.schoolClassNotice，经 serializeOnCreate → school_class_notice 参数
 * → 后端校验 staff + 班级圈分类 + 首帖后落 class_notice cf 并置顶；学生侧标记忽略。
 */
export default class SchoolClassNotice extends Component {
  @service currentUser;
  @service site;

  get composer() {
    return this.args.outletArgs?.model;
  }

  get isClassCircleCategory() {
    const id = this.composer?.categoryId;
    const slug = this.site.categories?.findBy?.("id", id)?.slug || "";
    return /^(xx|cz)-class-\d{4}-/.test(slug);
  }

  get shouldShow() {
    return (
      this.currentUser?.staff &&
      this.composer?.action === "createTopic" &&
      this.isClassCircleCategory
    );
  }

  get state() {
    return this.composer?.schoolClassNotice === true;
  }

  @action
  toggle() {
    this.composer?.set("schoolClassNotice", !this.state);
  }

  <template>
    {{#if this.shouldShow}}
      <div class="school-class-notice">
        <DToggleSwitch
          @state={{this.state}}
          @label="school_engine.class_notice_label"
          {{on "click" this.toggle}}
        />
        <p class="school-class-notice-hint">{{i18n "school_engine.class_notice_hint"}}</p>
      </div>
    {{/if}}
  </template>
}
