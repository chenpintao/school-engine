import Component from "@glimmer/component";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";
import SchoolReportModal from "./school-report-modal";

/**
 * 固定一键举报入口（帖子菜单）：任何登录用户都能看到。
 * 自己的帖子与已下架帖子不显示。
 */
export default class SchoolReportButton extends Component {
  @service modal;
  @service currentUser;

  get visible() {
    const post = this.args.post;
    if (!post || post.deleted_at) {
      return false;
    }
    return this.currentUser?.id !== post.user_id;
  }

  get label() {
    return i18n("school_engine.report.entry");
  }

  open = () => {
    this.modal.show(SchoolReportModal, {
      model: { postId: this.args.post.id },
    });
  };

  <template>
    {{#if this.visible}}
      <DButton
        class="post-action-menu__school-report"
        @action={{this.open}}
        @icon="flag"
        @title={{this.label}}
      />
    {{/if}}
  </template>
}
