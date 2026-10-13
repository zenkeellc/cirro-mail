import 'package:dio/dio.dart';

import '../../core/network/api_client.dart';
import '../../core/network/endpoints.dart';
import '../models/mail_page.dart';

/// 星标。
///
/// 服务端（`service/star-service.js`）：
/// - `POST /star/add` body `{emailId}`；重复标星是幂等的（表上有唯一约束）。
/// - `DELETE /star/cancel?emailId=` —— **query 参数**，不是 body。
/// - `GET /star/list` 返回**只有 `{list}`**，没有 `total`、没有 `latestEmail`
///   （与 `/email/list` 不同），所以 UI 不能显示星标总数。
/// - 列表里的 `isStar` 是服务端硬编码的 `1`，游标是 `star.emailId` 的降序
///   （`lt(star.emailId, emailId)`），与邮件列表的游标口径一致，可以复用。
class StarApi {
  const StarApi(this._client);

  final ApiClient _client;

  Future<MailPage> list({
    required String profileId,
    int? beforeEmailId,
    int size = 50,
    bool full = false,
    String mailboxEmail = '',
    CancelToken? cancelToken,
  }) async {
    final data = await _client.request<Object?>(
      Endpoints.starList,
      query: <String, dynamic>{
        'size': size,
        if (beforeEmailId != null && beforeEmailId > 0) 'emailId': beforeEmailId,
        'full': full ? 1 : 0,
      },
      cancelToken: cancelToken,
    );
    return MailPage.fromJson(
      data,
      profileId: profileId,
      mailboxEmail: mailboxEmail,
      pageSize: size,
    );
  }

  Future<void> add(int emailId) => _client.request<Object?>(
        Endpoints.starAdd,
        method: 'POST',
        data: <String, dynamic>{'emailId': emailId},
      );

  Future<void> cancel(int emailId) => _client.request<Object?>(
        Endpoints.starCancel,
        method: 'DELETE',
        query: <String, dynamic>{'emailId': emailId},
      );
}
