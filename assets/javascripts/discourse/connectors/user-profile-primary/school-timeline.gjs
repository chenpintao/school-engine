import Component from "@glimmer/component";
import SchoolTimeline from "../../components/school-timeline";

/**
 * 个人主页注入「时光」区块（user-profile-primary outlet，2026.x
 * 已无旧的 user-profile outlet）。
 * outlet model 为 User 对象，兼容历史 UserProfile（其 .user 为用户对象）。
 */
export default class SchoolTimelineConnector extends Component {
  get user() {
    const model = this.args.outletArgs?.model;
    return model?.user || model;
  }

  <template>
    <SchoolTimeline @user={{this.user}} />
  </template>
}
